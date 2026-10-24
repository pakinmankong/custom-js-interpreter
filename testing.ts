import "./tests/basic.test.js";
import "./tests/semicolon.test.js";
import "./tests/ast_cache.test.js";
import "./tests/functions.test.js";
import "./tests/errors.test.js";
import "./tests/async.test.js";
import assert from "node:assert/strict";
import test from "node:test";
import InterpreterService from "./lib/interpreter_service.js";
import { createFunctions } from "./lib/functions.js";

// Every case runs JS source through a new interpreter, with isolated data/services.
function setup() {
  const calls: any[][] = [];
  const standardRows = [
    { value: 20, uncertainty: 5 },
    { value: 10, uncertainty: 2 },
    { value: 30, uncertainty: 1 },
  ];
  let interpreter: InterpreterService;
  const functions = createFunctions({
    getEnv: () => interpreter.currentEnv,
    output: (...values) => {
      calls.push(values);
    },
    services: {
      getStandardErrors: (id) => (id === 1 ? standardRows : []),
      getUnitById: (id) =>
        id === 2
          ? { unit_id: 2, unit_short_name_en: "cm", unit_name_en: "centimetre" }
          : null,
      getUnitByName: (name) => (name === "metre" ? { unit_id: 1 } : null),
      convertUnit: (from, to, value) =>
        from === 1 && to === 2 ? value * 100 : null,
    },
  });
  interpreter = new InterpreterService({
    variables: {
      CURRENT_ROW: [1, 0],
      _UNIT_: { 1: { ID: 1, SYMBOL: "m", NAME: "metre" } },
    },
    functions,
  });
  return { functions, calls, execute: (code: string) => interpreter.execute(code) };
}

// One independently named test per function, including print.
type ValueCase = [name: string, expression: string, expected: unknown];

const cases: ValueCase[] = [
  [
    "SUCCESS",
    'SUCCESS(42, "ok")',
    { type: "success", value: 42, message: "ok" },
  ],
  [
    "ERROR",
    'ERROR("bad", { code: 1 })',
    { type: "error", message: "bad", data: { code: 1 } },
  ],
  ["FIRST", "FIRST([10,20])", 10],
  ["LAST", "LAST([10,20])", 20],
  ["COUNT", "COUNT([10,20])", 2],
  ["NUMBER", 'NUMBER("12.5")', 12.5],
  ["IS_INFINITY", 'IS_INFINITY("Infinity")', true],
  ["FIND_INDEX", 'FIND_INDEX([1,"2",2], 2, true)', 2],
  ["EXP", "EXP(0)", 1],
  [
    "FIND_REF_SETTING",
    "FIND_REF_SETTING({rows:[10,20],columns:[1],datas:[[3],[5]]},15)",
    5,
  ],
  ["SUMSQ", "SUMSQ([1,2,3])", 14],
  ["SORTING", 'SORTING([3,1,2], "desc")', [3, 2, 1]],
  ["FIND_STD_ERROR", "FIND_STD_ERROR(1,15)", { value: 20, uncertainty: 5 }],
  ["GET_STD_BY_INDEX", "GET_STD_BY_INDEX(1,0)", { value: 10, uncertainty: 2 }],
  ["GET_STD_BY_VALUE", "GET_STD_BY_VALUE(1,30)", { value: 30, uncertainty: 1 }],
  ["UNIT", "UNIT(1)", { ID: 1, SYMBOL: "m", NAME: "metre" }],
  ["UNIT_ID", 'UNIT_ID("metre")', 1],
  ["TREND", "TREND([2,4,6],[1,2,3],4)", 8],
  [
    "RAND",
    "RAND()",
    (value: number) => assert.ok(Number.isFinite(value) && value >= 0 && value < 1),
  ],
  [
    "RANDBETWEEN",
    "RANDBETWEEN(2,5)",
    (value: number) => assert.ok(Number.isInteger(value) && value >= 2 && value <= 5),
  ],
  ["UNIT_CONVERT", "UNIT_CONVERT(1,2,3)", 300],
  ["MIN", "MIN([3,1,2])", 1],
  ["MAX", "MAX([3,1,2])", 3],
  ["MAP", 'MAP([{v:"2"},{v:3}],"v")', [2, 3]],
  ["SUM", 'SUM([{v:2},{v:3}],"v")', 5],
  ["AVERAGE", "AVERAGE([2,4,6])", 4],
  ["STDEV", "STDEV([1,2,3])", 1],
  ["ABS", "ABS(-3)", 3],
  ["SQRT", "SQRT(16)", 4],
  ["GET_CURRENT_ROW_INDEX", "GET_CURRENT_ROW_INDEX()", 1],
  ["POWER", "POWER(2,3)", 8],
  ["LOG", "LOG(100)", 2],
  ["FIXED", "FIXED(1.5)", "1.50"],
  ["DECIMAL_PLACES", "DECIMAL_PLACES(1.25)", 2],
  ["STR", "STR(123)", "123"],
  ["NUM", 'NUM("12.5")', 12.5],
  ["ROW", "ROW([10,20])", 20],
  ["EMPTY", 'EMPTY("  ")', true],
  ["MATCH", "MATCH(25,[10,20,30])", 1],
  ["INDEX", "INDEX([[1,2],[3,4]],1,0)", 3],
  ["ISNULL", "ISNULL(null)", true],
  ["FORMAT_EXPO", "FORMAT_EXPO(1234,2)", "1.23e+3"],
  [
    "TINV",
    "TINV(0.05,10)",
    (value: number) => assert.ok(Math.abs(value - 2.2281388519649385) < 1e-6),
  ],
  ["ROUND", "ROUND(1.25,1)", 1.3],
  ["ROUNDUP", "ROUNDUP(-1.231,2)", -1.24],
  ["ROUNDDOWN", "ROUNDDOWN(-1.239,2)", -1.23],
  ["INT", "INT(-1.2)", -2],
  ["MMULT", "MMULT([[1,2]],[[3],[4]])", [[11]]],
  [
    "MINVERSE",
    "MINVERSE([[0,1],[1,0]])",
    [
      [0, 1],
      [1, 0],
    ],
  ],
  ["SIG", "SIG(12.34,2)", "13"],
  [
    "GOAL_SEEK",
    "GOAL_SEEK(x => x * 2, 10)",
    (value: number) => assert.ok(Math.abs(value - 5) < 1e-6),
  ],
  ["print", 'print("hello", 2+3)', undefined],
];

for (const [name, expression, expected] of cases) {
  test(`${name}: executes through InterpreterService`, () => {
    const { execute, calls } = setup();
    const actual = execute(`return ${expression};`);
    if (typeof expected === "function") expected(actual);
    else assert.deepEqual(actual, expected);
    if (name === "print") assert.deepEqual(calls, [["hello", 5]]);
  });
}

test("every registered function has an execution case", () => {
  const { functions } = setup();
  assert.deepEqual(
    Object.keys(functions).sort(),
    cases.map(([name]) => name).sort(),
  );
});

const edgeCases: ValueCase[] = [
  [
    "SUCCESS defaults",
    "SUCCESS()",
    { type: "success", value: null, message: undefined },
  ],
  ["ERROR defaults", "ERROR()", { type: "error", message: "", data: null }],
  ["FIRST empty", "FIRST([])", null],
  ["LAST empty", "LAST([])", null],
  ["LAST return index", "LAST([10,20],true)", 1],
  ["COUNT empty", "COUNT([])", 0],
  ["FIND_INDEX missing", "FIND_INDEX([1],2)", null],
  ["FIND_INDEX first", 'FIND_INDEX([2,"2"],2)', 0],
  ["IS_INFINITY negative", 'IS_INFINITY("-Infinity")', true],
  ["IS_INFINITY finite", "IS_INFINITY(5)", false],
  ["MAP exclude", 'MAP([{v:1},{v:2}],"v",[0],true)', [2]],
  ["MAP object keys", 'MAP({a:{v:1},b:{v:2}},"v",["b"])', [2]],
  ["MAP values", "MAP([1,2],null)", [1, 2]],
  ["SUM nested variadic", "SUM([1,[2]],3)", 6],
  ["SUM keyed object", 'SUM({a:{v:1},b:{v:2}},"v")', 3],
  ["AVERAGE empty", "AVERAGE([])", 0],
  ["STDEV empty", "STDEV([])", 0],
  ["STDEV singleton", "STDEV([1])", NaN],
  ["NUMBER invalid", 'NUMBER("bad")', NaN],
  ["NUM zero string", 'NUM("0")', 0],
  ["STR null", "STR(null)", "null"],
  ["EMPTY NaN", 'EMPTY(NUM("bad"))', true],
  ["EMPTY array", "EMPTY([])", true],
  ["EMPTY object", "EMPTY({})", false],
  ["EMPTY zero", "EMPTY(0)", false],
  ["ISNULL false", "ISNULL(false)", false],
  ["ROW manual index", "ROW([10,20],0)", 10],
  ["ROW nested level", "ROW([10,20],null,1)", 10],
  ["GET_CURRENT_ROW_INDEX nested", "GET_CURRENT_ROW_INDEX(1)", 0],
  ["MATCH exact", "MATCH(20,[10,20,30],0)", 1],
  ["MATCH descending", "MATCH(25,[30,20,10],-1)", 0],
  ["MATCH missing", "MATCH(5,[10,20])", -1],
  ["INDEX negative", "INDEX([[1]],-1,0)", null],
  ["ROUNDUP positive", "ROUNDUP(1.231,2)", 1.24],
  ["ROUNDDOWN positive", "ROUNDDOWN(1.239,2)", 1.23],
  ["ROUNDUP negative digits", "ROUNDUP(123,-1)", 130],
  ["ROUNDDOWN negative digits", "ROUNDDOWN(123,-1)", 120],
  ["TINV boundary", "TINV(1,10)", 0],
  ["SIG zero", "SIG(0)", "0"],
  ["SIG small number", "SIG(0.000123456)", "0.00013"],
  ["LOG natural", 'LOG(EXP(1),"e")', 1],
  ["RANDBETWEEN equal bounds", 'RANDBETWEEN("2.9","2.9")', 2],
  ["FIND_STD_ERROR exact index", 'FIND_STD_ERROR(1,10,"uncertainty",true)', 0],
  ["FIND_STD_ERROR out of range", "FIND_STD_ERROR(1,5)", null],
  ["FIND_STD_ERROR empty service result", "FIND_STD_ERROR(99)", null],
  ["GET_STD_BY_INDEX column", 'GET_STD_BY_INDEX(1,null,"value")', [10, 20, 30]],
  ["GET_STD_BY_INDEX missing", "GET_STD_BY_INDEX(1,99)", null],
  ["GET_STD_BY_VALUE missing", "GET_STD_BY_VALUE(1,99)", null],
  ["UNIT fallback", "UNIT(2)", { ID: 2, SYMBOL: "cm", NAME: "centimetre" }],
  ["UNIT missing", "UNIT(99)", null],
  ["UNIT_ID missing", 'UNIT_ID("unknown")', null],
  ["UNIT_CONVERT unsupported pair", "UNIT_CONVERT(2,1,3)", null],
  ["GOAL_SEEK zero target", "GOAL_SEEK(x=>x,0)", 0],
];
for (const [name, expression, expected] of edgeCases) {
  test(name, () =>
    assert.deepEqual(setup().execute(`return ${expression};`), expected),
  );
}

const errors: [name: string, expression: string, pattern: RegExp][] = [
  ["FIRST", "FIRST(1)", /array/],
  ["LAST", "LAST(null)", /array/],
  ["COUNT", "COUNT(1)", /array/],
  ["SORTING", "SORTING(1)", /array/],
  ["NUMBER", "NUMBER()", /expects/],
  ["IS_INFINITY", 'IS_INFINITY("bad")', /number/],
  ["FIND_INDEX", "FIND_INDEX(1,2)", /array/],
  ["EXP", 'EXP("bad")', /numeric/],
  ["MAP", 'MAP(1,"v")', /array or object/],
  ["ROW", "ROW([1],0.5)", /integer/],
  ["GET_CURRENT_ROW_INDEX", "GET_CURRENT_ROW_INDEX(99)", /CURRENT_ROW/],
  ["MATCH", "MATCH(1,[],2)", /matchType/],
  ["INDEX", "INDEX([[1]],0.5,0)", /integer/],
  ["FORMAT_EXPO", "FORMAT_EXPO(1,0.5)", /integer/],
  ["POWER", "POWER(2)", /expects/],
  ["SQRT", 'SQRT("bad")', /numeric/],
  ["ABS", 'ABS("bad")', /numeric/],
  ["LOG", 'LOG("bad")', /numeric/],
  ["FIXED", "FIXED(1,0.5)", /integer/],
  ["DECIMAL_PLACES", 'DECIMAL_PLACES("bad")', /numeric/],
  ["ROUND", 'ROUND("bad")', /numeric/],
  ["ROUNDUP", "ROUNDUP(1,0.5)", /integer/],
  ["ROUNDDOWN", "ROUNDDOWN(1,0.5)", /integer/],
  ["INT", 'INT("bad")', /finite number/],
  ["MMULT", "MMULT([[1,2]],[[1,2]])", /dimensions/],
  ["MINVERSE", "MINVERSE([[1,2],[2,4]])", /singular/],
  ["TINV", "TINV(0,10)", /probability/],
  ["TREND", "TREND([1,2])", /expects 3 arguments/],
  ["RANDBETWEEN", "RANDBETWEEN(5,2)", /bounds/],
  ["FIND_REF_SETTING", "FIND_REF_SETTING()", /ref_setting/],
  ["FIND_STD_ERROR", 'FIND_STD_ERROR(1,"bad")', /finite number/],
  ["GET_STD_BY_INDEX", "GET_STD_BY_INDEX(1,0.5)", /integer/],
  ["GET_STD_BY_VALUE", 'GET_STD_BY_VALUE(1,"bad")', /finite number/],
  ["UNIT", "UNIT()", /unit_id/],
  ["UNIT_ID", "UNIT_ID()", /unit_name/],
  ["UNIT_CONVERT", "UNIT_CONVERT(1,2)", /from_value/],
  ["GOAL_SEEK", "GOAL_SEEK(x=>1,2)", /could not be found/],
];
for (const [name, expression, pattern] of errors) {
  test(`${name}: invalid argument/error`, () => {
    assert.throws(() => setup().execute(`return ${expression};`), pattern);
  });
}
