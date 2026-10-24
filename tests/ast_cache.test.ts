import assert from "node:assert/strict";
import test from "node:test";
import parser from "@babel/parser";
import { AstCache } from "../lib/ast_cache.js";
import InterpreterService from "../lib/interpreter_service.js";

// Count real parser calls independently of the cache's own statistics.
function loadCounter() {
  let calls = 0;
  return {
    get calls() { return calls; },
    parse: (source: string) => { calls++; return parser.parse(source); },
  };
}

test("AST cache calls Babel once for identical source", () => {
  const cache = new AstCache();
  const loader = loadCounter();
  const first = cache.getOrParse("var n=1;", () => loader.parse("var n=1;"));
  const second = cache.getOrParse("var n=1;", () => loader.parse("var n=1;"));
  assert.equal(first, second);
  assert.equal(loader.calls, 1);
  assert.deepEqual(cache.stats, { size: 1, maxEntries: 100, hits: 1, misses: 1, evictions: 0 });
});

test("AST cache evicts the least recently used source at capacity", () => {
  const cache = new AstCache(2);
  const loader = loadCounter();
  const parse = (source: string) => cache.getOrParse(source, () => loader.parse(source));
  const firstB = parse("var a=1;");
  const secondB = parse("var b=2;");
  assert.equal(parse("var a=1;"), firstB); // Refresh a so b is evicted next.
  parse("var c=3;");
  assert.notEqual(parse("var b=2;"), secondB);
  assert.equal(loader.calls, 4);
  assert.deepEqual(cache.stats, { size: 2, maxEntries: 2, hits: 1, misses: 4, evictions: 2 });
});

test("syntax errors are retried and do not evict successful entries", () => {
  const cache = new AstCache(1);
  const loader = loadCounter();
  const valid = cache.getOrParse("var n=1;", () => loader.parse("var n=1;"));
  for (let i=0; i<2; i++) assert.throws(() => cache.getOrParse("const =", () => loader.parse("const =")), SyntaxError);
  assert.equal(cache.getOrParse("var n=1;", () => loader.parse("var n=1;")), valid);
  assert.equal(loader.calls, 3);
  assert.equal(cache.stats.evictions, 0);
});

test("cached ASTs are deeply frozen and cannot poison later parses", () => {
  const interpreter = new InterpreterService();
  const ast = interpreter.parse("var n=1;");
  assert.ok(Object.isFrozen(ast));
  assert.ok(Object.isFrozen(ast.program.body));
  assert.ok(Object.isFrozen(ast.program.body[0]));
  assert.throws(() => ast.program.body.pop(), TypeError);
  assert.equal(interpreter.parse("var n=1;").program.body.length, 1);
});

test("AST caching can be disabled for comparison", () => {
  const interpreter = new InterpreterService({ resolver: true, astCache: false });
  assert.equal(interpreter.astCache, null);
  assert.notEqual(interpreter.parse("var n=1;"), interpreter.parse("var n=1;"));
  assert.equal(interpreter.execute("return 2+3;"), 5);
  interpreter.clearAstCache(); // Safe when disabled.
});

test("execute reuses AST but reads current inputs and repeats side effects", () => {
  let calls = 0;
  const interpreter = new InterpreterService({ resolver: true, variables: { input: 1 }, functions: { count: () => ++calls } });
  const code = "return [input, count()];";
  assert.deepEqual(interpreter.execute(code), [1,1]);
  interpreter.globalEnv.set("input", 2);
  assert.deepEqual(interpreter.execute(), [2,2]);
  assert.equal(interpreter.astCache!.stats.misses, 1);
  assert.equal(interpreter.astCache!.stats.hits, 1);
});

test("repeated execution creates fresh objects and function closures", () => {
  const interpreter = new InterpreterService();
  const code = "const a=[];var n=0;function next(){return ++n;}a.push(next());return a;";
  const first = interpreter.execute(code);
  first.push(99);
  assert.deepEqual(interpreter.execute(code), [1]);
  assert.deepEqual(first, [1,99]);
});

test("repeated regex literals create fresh RegExp state", () => {
  const interpreter = new InterpreterService();
  const code = 'var regex=/a/g;return [regex.test("a"),regex.lastIndex];';
  assert.deepEqual(interpreter.execute(code), [true,1]);
  assert.deepEqual(interpreter.execute(code), [true,1]);
});

test("runtime failures do not cache an error or retain a failed scope", () => {
  const interpreter = new InterpreterService();
  assert.throws(() => interpreter.execute("return input;"), /Undefined variable: input/);
  interpreter.globalEnv.define("input", 7);
  assert.equal(interpreter.execute("return input;"), 7);
  assert.equal(interpreter.astCache!.stats.misses, 1);
  assert.equal(interpreter.astCache!.stats.hits, 1);
  assert.equal(interpreter.currentEnv, interpreter.globalEnv);
});

test("shared AST cache keeps interpreter globals and closures separate", () => {
  const cache = new AstCache(10);
  const a = new InterpreterService({ resolver: true, variables: { input: 1 }, astCache: cache });
  const b = new InterpreterService({ resolver: true, variables: { input: 9 }, astCache: cache });
  const code = "function read(){return input;}return read();";
  assert.equal(a.execute(code), 1);
  assert.equal(b.execute(code), 9);
  assert.equal(a.execute(code), 1);
  assert.equal(cache.stats.misses, 1);
  assert.equal(cache.stats.hits, 2);
});

test("same formula AST uses each data root and current resolver values", () => {
  const variables = {
    DATA: { A: "return B;", B: "return 1;" },
    OTHER: { A: "return B;", B: "return 2;" },
  };
  const interpreter = new InterpreterService({ resolver: true, variables });
  const code = "return [DATA.A,OTHER.A];";
  assert.deepEqual(interpreter.execute(code), [1,2]);
  assert.equal(interpreter.astCache!.stats.misses, 4); // main, shared A, two B formulas
  assert.equal(interpreter.astCache!.stats.hits, 1);
  variables.DATA.B = "return 3;";
  interpreter.dataResolver.clearCache();
  assert.deepEqual(interpreter.execute(code), [3,2]);
  assert.equal(interpreter.astCache!.stats.misses, 5);
});

test("AST cache does not replace DataResolver's formula result cache", () => {
  let calls = 0;
  const interpreter = new InterpreterService({ resolver: true, variables: { DATA: { A: "return count();" } }, functions: { count: () => ++calls } });
  const code = "return DATA.A;";
  assert.equal(interpreter.execute(code), 1);
  interpreter.clearAstCache();
  assert.equal(interpreter.execute(code), 1); // Resolver result survives AST clear.
  interpreter.dataResolver.clearCache();
  assert.equal(interpreter.execute(code), 2); // Formula executes again with fresh state.
  assert.equal(interpreter.astCache!.stats.misses, 2);
});

test("exact source keys include wrappers and whitespace", () => {
  const interpreter = new InterpreterService();
  assert.equal(interpreter.execute("return 1;"), 1);
  assert.equal(interpreter.execute("return  1;"), 1);
  assert.equal(interpreter.evaluateFormula("return 1;", "DATA", [], interpreter.globalEnv), 1);
  assert.equal(interpreter.astCache!.stats.misses, 3);
});

test("clear resets cache and counters, then the next execution parses again", () => {
  const interpreter = new InterpreterService();
  interpreter.execute("return 1;");
  interpreter.execute("return 1;");
  interpreter.clearAstCache();
  assert.deepEqual(interpreter.astCache!.stats, { size: 0, maxEntries: 100, hits: 0, misses: 0, evictions: 0 });
  assert.equal(interpreter.execute("return 1;"), 1);
  assert.equal(interpreter.astCache!.stats.misses, 1);
});

test("AST cache validates capacity and exposes a stats snapshot", () => {
  for (const n of [0,-1,0.5,NaN,Infinity]) assert.throws(() => new AstCache(n), RangeError);
  const cache = new AstCache();
  const stats = cache.stats;
  stats.hits = 999;
  assert.equal(cache.stats.hits, 0);
});

test("AST cache exports a detached, versioned JSON snapshot", () => {
  const interpreter = new InterpreterService();
  interpreter.execute("return 1;");
  const snapshot = interpreter.exportAstCache();
  assert.equal(snapshot.format, "custom-js-interpreter.ast-cache");
  assert.equal(snapshot.version, 1);
  assert.equal(snapshot.parser, "babel-7-script-v1");
  assert.equal(snapshot.entries.length, 1);
  assert.equal(snapshot.entries[0].source, "function __USER_MAIN__() {\nreturn 1;\n}");
  assert.deepEqual(JSON.parse(JSON.stringify(interpreter.astCache)), snapshot);
  assert.deepEqual(JSON.parse(JSON.stringify(snapshot)), snapshot);
  (snapshot.entries[0].ast as any).program.body.length = 0;
  assert.equal(interpreter.execute("return 1;"), 1);
});

test("export includes parsed dependency formulas and preserves BigInt/nonfinite literals", () => {
  const interpreter = new InterpreterService({ resolver: true, variables: { DATA: { A: "return 1n;" } } });
  assert.deepEqual(interpreter.execute("return [DATA.A,1e999];"), [1n,Infinity]);
  const snapshot = JSON.parse(JSON.stringify(interpreter.exportAstCache()));
  assert.equal(snapshot.entries.length, 2);
  const main = snapshot.entries.find((entry: any) => entry.source.includes("__USER_MAIN__"));
  assert.deepEqual(main.ast.program.body[0].body.body[0].argument.elements[1].value, { $number: "Infinity" });
  const formula = snapshot.entries.find((entry: any) => entry.source.includes("__FORMULA__"));
  assert.equal(formula.ast.program.body[0].body.body[0].argument.value, "1");
});

test("JSON export does not touch LRU ordering/counters and reports disabled cache", () => {
  const interpreter = new InterpreterService();
  interpreter.execute("return 1;");
  const stats = interpreter.astCache!.stats;
  interpreter.exportAstCache();
  assert.deepEqual(interpreter.astCache!.stats, stats);
  interpreter.clearAstCache();
  assert.deepEqual(interpreter.exportAstCache().entries, []);
  assert.throws(() => new InterpreterService({ resolver: true,astCache:false}).exportAstCache(), /disabled/);
});

test("compile prepares JSON without invoking code or host functions", () => {
  let calls = 0;
  const interpreter = new InterpreterService({ resolver: true,functions:{print:()=>calls++}});
  interpreter.compile('print("hello");return missing;');
  interpreter.compileFormula('return missingFormulaValue;');
  assert.equal(calls,0);
  assert.equal(interpreter.exportAstCache().entries.length,2);
  assert.equal(interpreter.currentEnv,interpreter.globalEnv);
  assert.equal(interpreter.dataResolver.cache.size,0);
});
