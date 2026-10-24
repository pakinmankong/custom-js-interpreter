import assert from "node:assert/strict";
import test from "node:test";
import InterpreterService from "../lib/interpreter_service.js";

// ASI does not allow arbitrary adjacent same-line statements. Keep Babel as the
// TS grammar authority rather than stripping punctuation from user source.
for (const code of [
  'var a=1 var b=2',
  'var text=`a\nb` var n=2',
  'var text="a\nb"',
]) {
  test(`semicolon grammar rejects invalid source: ${JSON.stringify(code)}`, () => {
    assert.throws(() => new InterpreterService().compile(code), SyntaxError);
  });
}
