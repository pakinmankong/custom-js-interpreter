import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import InterpreterService from "../lib/interpreter_service.js";

// Shared with the Dart basic suite. Keep these independently of function tables.
const fixtures: {name:string;code:string;expected?:any;error?:string}[] = JSON.parse(
  fs.readFileSync(new URL("./basic_cases.json", import.meta.url), "utf8"),
);
function decode(value: any): any {
  if (value && typeof value === "object" && value.$undefined === true) return undefined;
  if (Array.isArray(value)) return value.map(decode);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key,v]) => [key,decode(v)]));
  return value;
}
for (const fixture of fixtures) {
  test(`basic: ${fixture.name}`, () => {
    const interpreter = new InterpreterService();
    if (fixture.error) assert.throws(() => interpreter.execute(fixture.code),new RegExp(fixture.error));
    else assert.deepEqual(interpreter.execute(fixture.code),decode(fixture.expected));
  });
}

test('resolver is disabled by default and enabled only with resolver: true', () => {
  const variables = { DATA: { value: 'return 5', cell: {formula: 'return 6'}, unit: 'uuid-text' } };
  for (const context of [{variables}, {variables, resolver: false}]) {
    const interpreter = new InterpreterService(context);
    assert.deepEqual(interpreter.execute('return [DATA.value, DATA.cell.formula, DATA.unit];'), ['return 5','return 6','uuid-text']);
    assert.equal(interpreter.dataResolver.cache.size, 0);
  }
  const interpreter = new InterpreterService({variables, resolver: true});
  assert.deepEqual(interpreter.execute('return [DATA.value, DATA.cell, DATA.unit];'), [5,6,'uuid-text']);
});
