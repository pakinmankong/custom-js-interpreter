import assert from "node:assert/strict";
import test from "node:test";
import InterpreterService from "../lib/interpreter_service.js";
import { createInterpreterError, formatInterpreterError } from "../lib/errors.js";
import { createFunctions } from "../lib/functions.js";

test("external runtime error formatting uses node loc.start and preserves directive lines", () => {
  const interpreter = new InterpreterService();
  const code = "#CURRENT_ROW = 0,1\n\nsdfds";
  let raw: any;
  try { interpreter.execute(code); } catch (error) { raw = error; }
  assert.ok(raw instanceof Error);
  assert.equal((raw as any).loc.start.line, 4);
  const error = createInterpreterError(raw, "script", interpreter.lineOffset, code);
  assert.equal(error.line, 3);
  assert.equal(error.column, 0);
  assert.equal(error.length, 5);
  assert.equal(error.position, (raw as any).pos);
  assert.match(formatInterpreterError(error), /error at line 3,/);
  assert.doesNotMatch(formatInterpreterError(error), /\n(?:>|    \|)/);
  assert.equal(createInterpreterError(error, "script", 1), error);
});

test("syntax error formatting supports Babel loc.line", () => {
  const interpreter = new InterpreterService();
  assert.throws(() => interpreter.execute("#CURRENT_ROW=\nconst ="), (raw: any) => {
    const error = createInterpreterError(raw, "script", interpreter.lineOffset, interpreter.userCode);
    assert.equal(error.line, 2);
    assert.equal(error.position, raw.pos);
    assert.match(formatInterpreterError(error), /error at line 2,/);
    return true;
  });
});

test("external error formatting reads position from loc index and handles CR newlines", () => {
  const error = createInterpreterError({message: "bad", loc: {start: {line: 2, column: 1, index: 3}}}, "script", 0, "a\rbad");
  assert.equal(error.position, 3);
  assert.match(formatInterpreterError(error), /error at line 2,/);
});

test("runtime line formatting supports every JavaScript newline after ignored metadata", () => {
  for (const newline of ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
    const code = `#CURRENT_ROW=0,1${newline}sdfds`;
    const interpreter = new InterpreterService();
    assert.throws(() => interpreter.execute(code), (raw: any) => {
      const error = createInterpreterError(raw, 'script', interpreter.lineOffset, code);
      assert.equal(error.line, 2);
      assert.equal(error.column, 0);
      assert.match(formatInterpreterError(error), /error at line 2,/);
      return true;
    });
  }
});

test("nested data formula errors retain the actual source rather than the caller script", () => {
  const formula = 'return 123invalid';
  let interpreter: InterpreterService;
  interpreter = new InterpreterService({ resolver: true,
    variables: { CURRENT_ROWS: [0], _RECORDS_: { MAIN_GROUP: { formula } } },
    functions: createFunctions({getEnv: () => interpreter.currentEnv}),
  });
  const code = 'var point = ROW(_RECORDS_.MAIN_GROUP); return point;';
  assert.throws(() => interpreter.execute(code), (raw: any) => {
    const error = createInterpreterError(raw, 'script', interpreter.lineOffset, code);
    assert.equal(error.source, '_RECORDS_.MAIN_GROUP');
    assert.equal(error.sourceCode, formula);
    assert.equal(error.line, 1);
    assert.match(formatInterpreterError(error), /_RECORDS_\.MAIN_GROUP error at line 1,/);
    assert.equal(interpreter.dataResolver.evaluating.length, 0);
    return true;
  });
});

test("data strings stay literal while legacy and explicit formulas still execute", () => {
  const id = 'bd4d74c0-275e-45b5-928b-68fa4f30a505';
  const interpreter = new InterpreterService({ resolver: true, variables: {
    _UUC_DETAIL_: { unit: id, resolution: '0.1', make: 'Magnetic Flowmeter', empty: '', numericText: '123invalid' },
    DATA: { A: 'return 5;', B: '// comment\n#CURRENT_ROW=0\nreturn A+1;', C: {formula: 'return 7;'}, bad: {formula: '123invalid'} },
  }});
  assert.deepEqual(interpreter.execute('return [_UUC_DETAIL_["unit"],_UUC_DETAIL_.resolution,_UUC_DETAIL_.make,_UUC_DETAIL_.empty,_UUC_DETAIL_.numericText,DATA.A,DATA.B,DATA.C];'), [id,'0.1','Magnetic Flowmeter','','123invalid',5,6,7]);
  assert.throws(() => interpreter.execute('return DATA.bad;'), /Identifier directly after number/);
});

test('error length supports explicit spans, loc columns and missing metadata', () => {
  assert.equal(createInterpreterError({message:'bad',start:2,end:8},'script').length,6);
  assert.equal(createInterpreterError({message:'bad',length:3},'script').length,3);
  assert.equal(createInterpreterError({message:'bad',loc:{start:{line:1,column:2},end:{line:1,column:7}}},'script').length,5);
  assert.equal(createInterpreterError(new Error('bad'),'script').length,1);
  assert.equal(createInterpreterError({message:'bad',length:-1},'script').length,1);
});

test('async runtime error includes the offending identifier length', async () => {
  const interpreter = new InterpreterService();
  await assert.rejects(interpreter.executeAsync('return missingValue;'), (raw: any) => {
    const error = createInterpreterError(raw,'script',1,interpreter.userCode);
    assert.equal(error.length,12);
    return true;
  });
});
