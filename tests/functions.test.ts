import assert from "node:assert/strict";
import test from "node:test";
import InterpreterService from "../lib/interpreter_service.js";
import { createFunctions, type FunctionServices } from "../lib/functions.js";

function setup(variables: Record<string, any> = {}, services: FunctionServices = {}) {
  const calls: any[][] = [];
  let interpreter: InterpreterService;
  const functions = createFunctions({
    getEnv: () => interpreter.currentEnv,
    services,
    output: (...values) => { calls.push(values); },
  });
  interpreter = new InterpreterService({ variables, functions });
  return { interpreter, functions, calls, execute: (code: string) => interpreter.execute(code) };
}
function near(actual: number, expected: number, tolerance = 1e-7) {
  assert.ok(Math.abs(actual - expected) < tolerance, `Expected ${expected}, received ${actual}`);
}

test("register all 51 reference functions with direct parameters", () => {
  const names = "SUCCESS ERROR FIRST LAST COUNT NUMBER IS_INFINITY FIND_INDEX EXP FIND_REF_SETTING SUMSQ SORTING FIND_STD_ERROR GET_STD_BY_INDEX GET_STD_BY_VALUE UNIT UNIT_ID TREND RAND RANDBETWEEN UNIT_CONVERT MIN MAX MAP SUM AVERAGE STDEV ABS SQRT GET_CURRENT_ROW_INDEX POWER LOG FIXED DECIMAL_PLACES STR NUM ROW EMPTY MATCH INDEX ISNULL FORMAT_EXPO TINV ROUND ROUNDUP ROUNDDOWN INT MMULT MINVERSE SIG GOAL_SEEK".split(" ");
  const { functions } = setup();
  for (const name of names) assert.equal(typeof (functions as Record<string, any>)[name], "function", name);
});

test("SUCCESS and ERROR accept optional values and defaults", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [SUCCESS(), SUCCESS(5, "ok"), ERROR(), ERROR("bad", {code: 1})];`), [
    {type: "success", value: null, message: undefined}, {type: "success", value: 5, message: "ok"},
    {type: "error", message: "", data: null}, {type: "error", message: "bad", data: {code: 1}},
  ]);
});

test("FIRST LAST COUNT SORTING use evaluated array arguments", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`var a=[3,1,2]; return [FIRST(a), LAST(a), LAST(a,true), COUNT(a), SORTING(a), SORTING([3,1,2],"desc"), FIRST([]), LAST([])];`), [3,2,2,3,[1,2,3],[3,2,1],null,null]);
});

test("FIND_INDEX normalizes numbers, searches last match, returns null if missing", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [FIND_INDEX([1,"2",2],2), FIND_INDEX([1,"2",2],"2",true), FIND_INDEX([],1)];`), [1,2,null]);
});

test("MAP maps object fields with include/exclude filters and numeric coercion", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`var data=[{v:"2"},{v:3},{v:"text"}]; return [MAP(data,"v"),MAP(data,"v",[0,2]),MAP(data,"v",[1],true),MAP({a:{v:4},b:{v:5}},"v",["b"]),MAP([1,2],null)];`), [[2,3,"text"],[2,"text"],[2,"text"],[5],[1,2]]);
});

test("SUM supports keyed arrays, keyed objects and existing variadic form", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [SUM([{v:"2"},{v:3}],"v"),SUM({a:{v:4},b:{v:5}},"v"),SUM([1,[2]],3),SUM({a:1})];`), [5,9,6,0]);
});

test("EMPTY handles arrays NaN objects zero and whitespace without trim errors", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [EMPTY([]),EMPTY([1]),EMPTY(NUM("bad")),EMPTY({}),EMPTY(0),EMPTY(false),EMPTY("  "),EMPTY(null)];`), [true,false,true,false,false,false,true,true]);
});

test("AVERAGE STDEV FIXED and IS_INFINITY compatibility", () => {
  const { execute } = setup();
  const result = execute(`return [AVERAGE([]),STDEV([]),FIXED(1.5),IS_INFINITY("Infinity"),IS_INFINITY(2),AVERAGE(1,2,3),STDEV([1,2,3])];`);
  assert.deepEqual(result, [0,0,"1.50",true,false,2,1]);
});

test("STR NUM ISNULL FORMAT_EXPO ROUNDUP ROUNDDOWN INT", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [STR(12),NUM("12"),ISNULL(null),ISNULL(0),FORMAT_EXPO(1234,2),ROUNDUP(1.231,2),ROUNDUP(-1.231,2),ROUNDDOWN(1.239,2),ROUNDDOWN(-1.239,2),INT(-1.2)];`), ["12",12,true,false,"1.23e+3",1.24,-1.24,1.23,-1.23,-2]);
});

test("ROW and GET_CURRENT_ROW_INDEX use active function environment", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`var CURRENT_ROW=[1,0]; return [ROW([10,20]),ROW([10,20],0),ROW([10,20],false,1),GET_CURRENT_ROW_INDEX(),GET_CURRENT_ROW_INDEX(1)];`), [20,10,10,1,0]);
  assert.equal(execute(`return ROW([10,20],1);`),20);
  assert.throws(() => execute(`return GET_CURRENT_ROW_INDEX();`), /CURRENT_ROW/);
  assert.throws(() => execute(`var CURRENT_ROW=[0]; return GET_CURRENT_ROW_INDEX(1);`), /CURRENT_ROW/);
});

test("MATCH is zero based with exact ascending and descending modes", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return [MATCH(20,[10,20,30],0),MATCH(25,[10,20,30]),MATCH(25,[30,20,10],-1),MATCH(5,[10,20]),MATCH(99,[10,20],0),INDEX([[1,2],[3,4]],1,0),INDEX([[1]],-1,0)];`), [1,1,0,-1,-1,3,null]);
});

test("FIND_REF_SETTING returns exact value or conservative adjacent maximum", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`var s={rows:[10,20],columns:[1,2],datas:[[3,4],[5,6]]};return [FIND_REF_SETTING(s,10),FIND_REF_SETTING(s,15,2),FIND_REF_SETTING(s,1),FIND_REF_SETTING(s,10,0)];`), [3,6,null,null]);
});

test("MMULT and MINVERSE work through the interpreter", () => {
  const { execute } = setup();
  assert.deepEqual(execute(`return MMULT([[1,2],[3,4]],[[5,6],[7,8]]);`), [[19,22],[43,50]]);
  const identity = execute(`var a=[[4,7],[2,6]];return MMULT(a,MINVERSE(a));`);
  near(identity[0][0],1); near(identity[0][1],0); near(identity[1][0],0); near(identity[1][1],1);
  assert.deepEqual(execute(`return MINVERSE([[0,1],[1,0]]);`),[[0,1],[1,0]]);
  assert.throws(() => execute(`return MINVERSE([[1,2],[2,4]]);`), /singular/);
  assert.throws(() => execute(`return MMULT([[1,2]],[[1,2]]);`), /dimensions/);
  assert.throws(() => execute(`return MINVERSE([[1,2],[3]]);`), /rectangular/);
});

test("TINV matches known two-tailed Student t values", () => {
  const { execute } = setup();
  near(execute(`return TINV(0.05,10);`),2.2281388519649385,1e-6);
  near(execute(`return TINV(0.05,1);`),12.706204736432095,1e-5);
  assert.equal(execute(`return TINV(1,10);`),0);
  assert.throws(() => execute(`return TINV(0,10);`), /probability/);
  assert.throws(() => execute(`return TINV(0.05,0);`), /degrees_of_freedom/);
});

test("GOAL_SEEK invokes interpreted callback with closure", () => {
  const { execute } = setup();
  near(execute(`const factor=2;return GOAL_SEEK(x=>x*factor,10);`),5,1e-6);
  near(execute(`return GOAL_SEEK(function(x){return x*x;},9);`),-3,1e-6);
  assert.equal(execute(`return GOAL_SEEK(x=>x,0);`),0);
  assert.throws(() => execute(`return GOAL_SEEK(x=>1,2);`), /could not be found/);
  assert.throws(() => execute(`return GOAL_SEEK(1,2);`), /must be a function/);
});

test("standard services sort a copy and handle exact adjacent and out-of-range lookup", () => {
  const data = [{value:20,uncertainty:5},{value:10,uncertainty:2},{value:30,uncertainty:1}];
  const { execute } = setup({}, {getStandardErrors: id => id===1 ? data : []});
  assert.deepEqual(execute(`return [FIND_STD_ERROR(1),FIND_STD_ERROR(1,10,"uncertainty",true),FIND_STD_ERROR(1,15,"uncertainty",true),FIND_STD_ERROR(1,25,"uncertainty",true),FIND_STD_ERROR(1,5),FIND_STD_ERROR(2),GET_STD_BY_INDEX(1,1),GET_STD_BY_INDEX(1,null,"value"),GET_STD_BY_INDEX(1,10),GET_STD_BY_VALUE(1,30),GET_STD_BY_VALUE(1,99)];`), [data[1],0,1,1,null,null,data[0],[10,20,30],null,data[2],null]);
  assert.equal(data[0].value,20);
});

test("UNIT uses _UNIT_ before service and normalizes external records", () => {
  const { execute } = setup({_UNIT_: {'1': {ID:1,SYMBOL:'m',NAME:'metre'}}}, {
    getUnitById: id => id===2 ? {unit_id:2,unit_short_name_en:'cm',unit_name_en:'centimetre'} : null,
    getUnitByName: name => name==='metre' ? {unit_id:1} : null,
    convertUnit: (from,to,value) => from===1 && to===2 ? value*100 : null,
  });
  assert.deepEqual(execute(`return [UNIT(1),UNIT(2),UNIT(99),UNIT_ID("metre"),UNIT_ID("missing"),UNIT_CONVERT(1,2,3)];`), [{ID:1,SYMBOL:'m',NAME:'metre'},{ID:2,SYMBOL:'cm',NAME:'centimetre'},null,1,null,300]);
});

test("external functions report missing services rather than silently returning fake data", () => {
  const { execute } = setup();
  for (const code of ['FIND_STD_ERROR(1)','GET_STD_BY_INDEX(1,0)','GET_STD_BY_VALUE(1,0)','UNIT(1)','UNIT_ID("m")','UNIT_CONVERT(1,2,1)']) {
    assert.throws(() => execute(`return ${code};`), /service is not configured/);
  }
});

test("Promise providers and callbacks are explicitly rejected", () => {
  const { execute } = setup({}, {getStandardErrors: (()=>Promise.resolve([])) as any});
  assert.throws(() => execute(`return FIND_STD_ERROR(1);`), /Promise is not supported/);
  const functions = createFunctions();
  assert.throws(() => functions.GOAL_SEEK((()=>Promise.resolve(1)) as any,2), /Promise is not supported/);
});

test("validation and TREND checks missing knownXValues", () => {
  const { execute } = setup();
  assert.throws(() => execute(`return FIRST(1);`), /array/);
  assert.throws(() => execute(`return ROUNDUP(1,0.5);`), /integer/);
  assert.throws(() => execute(`return MATCH(1,[],2);`), /matchType/);
  assert.throws(() => execute(`return TREND([1,2]);`), /expects 3 arguments/);
  assert.equal(execute(`return RANDBETWEEN("2.9","2.9");`),2);
});

test("CURRENT_ROWS host input drives row functions and takes precedence over CURRENT_ROW", () => {
  const { execute } = setup({ CURRENT_ROWS: [0, 1], CURRENT_ROW: [1, 0] });
  assert.deepEqual(execute(`return [ROW([10,20]),ROW([10,20],null,1),GET_CURRENT_ROW_INDEX(),GET_CURRENT_ROW_INDEX(1),ROW([10,20],1)];`), [10,20,0,1,20]);
  assert.throws(() => execute(`return GET_CURRENT_ROW_INDEX(2);`), /CURRENT_ROWS\[2\]/);
  assert.deepEqual(setup({ CURRENT_ROWS: [0,0] }).execute(`return [GET_CURRENT_ROW_INDEX(),GET_CURRENT_ROW_INDEX(1)];`), [0,0]);
});

test("row directive is ignored and host variables supply row indices", () => {
  const code = '#CURRENT_ROW = 0,1\nreturn [GET_CURRENT_ROW_INDEX(),GET_CURRENT_ROW_INDEX(1),ROW([10,20],null,1)];';
  assert.throws(() => setup().execute(code), /CURRENT_ROW/);
  assert.deepEqual(setup({ CURRENT_ROWS: [1,0] }).execute('// row settings\n/* defaults */\n#CURRENT_ROW = 0,1 // levels\nreturn [GET_CURRENT_ROW_INDEX(), GET_CURRENT_ROW_INDEX(1)];'), [1,0]);
  assert.deepEqual(setup({ CURRENT_ROWS: [1,0] }).execute(code), [1,0,10]);
  assert.deepEqual(setup({ CURRENT_ROW: [1,0] }).execute(code), [1,0,10]);
  const { interpreter, execute } = setup({ CURRENT_ROWS: [1,0] });
  interpreter.compile(code);
  for (const directive of ['#CURRENT_ROW=', '#CURRENt_ROW=0,1', '#current_row= // ignored', '#CURRENT_ROW=;']) {
    assert.deepEqual(execute(`${directive}\nreturn [GET_CURRENT_ROW_INDEX(), GET_CURRENT_ROW_INDEX(1)];`), [1,0]);
    assert.equal(setup().execute(`${directive}\nreturn 42;`), 42);
  }
  assert.deepEqual(execute(code), [1,0,10]);
  assert.deepEqual(execute('#CURRENT_ROW = 1,0\nreturn [GET_CURRENT_ROW_INDEX(),GET_CURRENT_ROW_INDEX(1)];'), [1,0]);
  assert.equal(execute('return `hello\n#CURRENT_ROW = 9,9\nworld`;'), 'hello\n#CURRENT_ROW = 9,9\nworld');
  assert.deepEqual(execute(`var x=10;
#CURRENT_ROW = 0,1
function rows() {
  #current_row=
  return [GET_CURRENT_ROW_INDEX(), GET_CURRENT_ROW_INDEX(1), x];
}
#CURRENt_ROW=9,9
return rows();`), [1,0,10]);
  assert.equal(execute('var text = `outer ${`inner`}\n#CURRENT_ROW=9,9\nend`;\n#CURRENT_ROW=\nreturn text;'), 'outer inner\n#CURRENT_ROW=9,9\nend');
});

test("ignore one, two and three row indices individually and on consecutive lines", () => {
  const directives = ['#CURRENT_ROW = 0', '#CURRENT_ROW = 0,0', '#CURRENT_ROW = 0,0,0'];
  for (const metadata of [...directives, directives.join('\n')]) {
    const { execute } = setup({ CURRENT_ROWS: [1,0] });
    assert.deepEqual(execute(`${metadata}\nreturn [ROW([10,20]),GET_CURRENT_ROW_INDEX(1)];`), [20,0]);
    assert.equal(setup().execute(`${metadata}\nreturn 42;`), 42);
  }
});

test("existing numeric functions still work and print is injectable", () => {
  const { execute, calls } = setup();
  assert.deepEqual(execute(`print("ok");return [NUMBER("2"),EXP(0),SUMSQ(1,2,3),TREND([2,4,6],[1,2,3],4),MIN([3,1]),MAX(1,3),ABS(-1),SQRT(4),POWER(2,3),LOG(100),DECIMAL_PLACES(1.25),ROUND(1.25,1),SIG(0)];`),[2,1,14,8,1,3,1,2,8,2,2,1.3,"0"]);
  assert.deepEqual(calls,[["ok"]]);
  const random = execute(`return RAND();`);
  assert.ok(random>=0 && random<1);
});
