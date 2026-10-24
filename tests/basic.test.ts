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
