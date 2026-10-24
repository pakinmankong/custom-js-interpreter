// Public package API only: run after build, without tsx or direct source imports.
import assert from 'node:assert/strict';
import test from 'node:test';
import Interpreter, {
  InterpreterService, Env, DataResolver, createFunctions, matchValue, AstCache,
  InterpreterError, createInterpreterError, formatInterpreterError,
} from 'custom-js-interpreter';

test('package exports the interpreter without executing the index.ts example', () => {
  assert.equal(Interpreter, InterpreterService);
  assert.equal(new InterpreterService().execute('return 2 + 3;'), 5);
  assert.equal(typeof Env, 'function');
  assert.equal(typeof DataResolver, 'function');
});
test('compiled package supports closures and native array callbacks', () => {
  assert.deepEqual(new InterpreterService().execute('const n=2;return [1,2,3].map(v=>v*n);'), [2,4,6]);
});
test('compiled functions register and invoke host callbacks', () => {
  let interpreter;
  interpreter = new InterpreterService({functions:createFunctions({getEnv:()=>interpreter.currentEnv})});
  const result = interpreter.execute('return [SUM([1,2,3]),GOAL_SEEK(x=>x*2,10),TINV(0.05,10)];');
  assert.equal(result[0],6);
  assert.ok(Math.abs(result[1]-5)<1e-6);
  assert.ok(Math.abs(result[2]-2.2281388519649385)<1e-6);
});
test('compiled resolver handles forward references and caches results', () => {
  const interpreter = new InterpreterService({resolver:true,variables:{DATA:{columns:[{name:'A',formula:'return B + 1'},{name:'B',formula:'return 10'}]}}});
  assert.equal(interpreter.execute('return DATA.A;'),11);
  assert.equal(interpreter.dataResolver.cache.get('DATA.A'),11);
});
test('compiled error and environment APIs are usable', () => {
  const env=new Env(); env.define('n',1,true);
  assert.throws(()=>env.set('n',2),/constant/);
  const error = createInterpreterError({message:'bad',loc:{line:1,column:0}},'script',0,'return missing;');
  assert.ok(error instanceof InterpreterError);
  assert.match(formatInterpreterError(error),/bad/);
  assert.equal(matchValue(20,[10,20,30],0),1);
});

test('compiled package exports an AST cache that can be shared across instances', () => {
  const cache = new AstCache(2);
  const a = new InterpreterService({astCache:cache,variables:{input:1}});
  const b = new InterpreterService({astCache:cache,variables:{input:9}});
  assert.equal(a.execute('return input;'),1);
  assert.equal(b.execute('return input;'),9);
  assert.equal(cache.stats.misses,1);
  assert.equal(cache.stats.hits,1);
  b.clearAstCache();
  assert.equal(cache.stats.size,0);
});

test('compiled package can prepare portable JSON without evaluating code', () => {
  const interpreter = new InterpreterService({astCache:new AstCache()});
  interpreter.compile('return unknownInput;');
  interpreter.compileFormula('return B + 1;');
  const payload=JSON.parse(JSON.stringify(interpreter.exportAstCache()));
  assert.equal(payload.format,'custom-js-interpreter.ast-cache');
  assert.equal(payload.version,1);
  assert.equal(payload.entries.length,2);
});

test('compiled package awaits custom async functions before evaluating dependent expressions', async () => {
  const interpreter = new InterpreterService({functions:{
    ...createFunctions(),
    FIND_STD_ERROR: async (id, value) => { await Promise.resolve(); return {uncertainty:value*2}; },
  }});
  assert.equal(await interpreter.executeAsync('var row=FIND_STD_ERROR(1,5);return row.uncertainty+1;'),11);
});
