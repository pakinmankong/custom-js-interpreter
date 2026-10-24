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
  assert.equal(error.position, (raw as any).pos);
  assert.match(formatInterpreterError(error), /> 3 \| sdfds/);
  assert.equal(createInterpreterError(error, "script", 1), error);
});

test("syntax error formatting supports Babel loc.line", () => {
  const interpreter = new InterpreterService();
  assert.throws(() => interpreter.execute("#CURRENT_ROW=\nconst ="), (raw: any) => {
    const error = createInterpreterError(raw, "script", interpreter.lineOffset, interpreter.userCode);
    assert.equal(error.line, 2);
    assert.equal(error.position, raw.pos);
    assert.match(formatInterpreterError(error), /> 2 \| const =/);
    return true;
  });
});

test("external error formatting reads position from loc index and handles CR newlines", () => {
  const error = createInterpreterError({message: "bad", loc: {start: {line: 2, column: 1, index: 3}}}, "script", 0, "a\rbad");
  assert.equal(error.position, 3);
  assert.match(formatInterpreterError(error), /> 2 \| bad/);
});

test("runtime line formatting supports every JavaScript newline after ignored metadata", () => {
  for (const newline of ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
    const code = `#CURRENT_ROW=0,1${newline}sdfds`;
    const interpreter = new InterpreterService();
    assert.throws(() => interpreter.execute(code), (raw: any) => {
      const error = createInterpreterError(raw, 'script', interpreter.lineOffset, code);
      assert.equal(error.line, 2);
      assert.equal(error.column, 0);
      assert.match(formatInterpreterError(error), /> 2 \| sdfds/);
      return true;
    });
  }
});

test("nested data formula errors retain the actual source rather than the caller script", () => {
  const formula = 'return 123invalid';
  let interpreter: InterpreterService;
  interpreter = new InterpreterService({
    variables: { CURRENT_ROWS: [0], _RECORDS_: { MAIN_GROUP: { formula } } },
    functions: createFunctions({getEnv: () => interpreter.currentEnv}),
  });
  const code = 'var point = ROW(_RECORDS_.MAIN_GROUP); return point;';
  assert.throws(() => interpreter.execute(code), (raw: any) => {
    const error = createInterpreterError(raw, 'script', interpreter.lineOffset, code);
    assert.equal(error.source, '_RECORDS_.MAIN_GROUP');
    assert.equal(error.sourceCode, formula);
    assert.equal(error.line, 1);
    assert.match(formatInterpreterError(error), /> 1 \| return 123invalid/);
    assert.equal(interpreter.dataResolver.evaluating.length, 0);
    return true;
  });
});
