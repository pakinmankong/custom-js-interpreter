import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import InterpreterService from '../lib/interpreter_service.js';
import { createFunctions } from '../lib/functions.js';
import { createInterpreterError } from '../lib/errors.js';

const cases = JSON.parse(fs.readFileSync(new URL('./async_cases.json', import.meta.url), 'utf8'));
function decode(value: any): any {
  if (value?.$undefined) return undefined;
  if (Array.isArray(value)) return value.map(decode);
  return value;
}
function setup(extra: Record<string, any> = {}, resolver = false) {
  const calls: any[][] = [];
  let interpreter: InterpreterService;
  const later = async <T>(value: T) => { await new Promise(resolve => setTimeout(resolve, 1)); return value; };
  interpreter = new InterpreterService({resolver, variables: extra, functions: {
    ...createFunctions({getEnv: () => interpreter.currentEnv}),
    DOUBLE: async (n: number) => later(n * 2),
    COMPARE: async (a: number, b: number) => later(a - b),
    FIND_STD_ERROR: async (_id: number, value: number) => later({uncertainty: value * 2}),
    FAIL: async () => { await later(0); throw new Error('service failed'); },
    HOST_APPLY: async (fn: (n: number) => any, n: number) => await fn(n),
    print: async (...values: any[]) => { await later(0); calls.push(values); },
  }});
  return {interpreter, calls};
}
for (const fixture of cases) {
  test(`async: ${fixture.name}`, async () => {
    const {interpreter, calls} = setup();
    if (fixture.error) {
      await assert.rejects(interpreter.executeAsync(fixture.code), (raw: any) => {
        assert.match(raw.message, new RegExp(fixture.error));
        assert.equal(createInterpreterError(raw, 'script', 1, fixture.code).line, fixture.line);
        return true;
      });
    } else {
      assert.deepEqual(await interpreter.executeAsync(fixture.code), decode(fixture.expected));
      assert.deepEqual(calls, fixture.calls ?? []);
    }
    assert.equal(interpreter.currentEnv, interpreter.globalEnv);
  });
}

test('async resolver awaits dependencies and preserves formula source on rejection', async () => {
  const {interpreter} = setup({DATA:{A:'return DOUBLE(B);', B:'return DOUBLE(2);', bad:{formula:'\nFAIL();'}}},true);
  assert.equal(await interpreter.executeAsync('return DATA.A;'),8);
  assert.equal(await interpreter.executeAsync('return DATA.A;'),8);
  await assert.rejects(interpreter.executeAsync('return DATA.bad;'), (error: any) => {
    assert.equal(error.source,'DATA.bad'); assert.equal(error.line,2); return true;
  });
  assert.equal(interpreter.dataResolver.evaluating.length,0);
});

test('async execution reuses AST without reusing result or suppressing effects', async () => {
  const {interpreter,calls} = setup({input:2});
  const code='print(input);return DOUBLE(input);';
  assert.equal(await interpreter.executeAsync(code),4);
  interpreter.globalEnv.set('input',3);
  assert.equal(await interpreter.executeAsync(code),6);
  assert.deepEqual(calls,[[2],[3]]);
  assert.equal(interpreter.astCache!.stats.hits,1);
});

test('overlapping executions are rejected and rejection releases the interpreter', async () => {
  const {interpreter} = setup();
  const first=interpreter.executeAsync('return DOUBLE(2);');
  await assert.rejects(interpreter.executeAsync('return 99;'),/already running/);
  assert.throws(()=>interpreter.execute('return 99;'),/already running/);
  assert.equal(await first,4);
  await assert.rejects(interpreter.executeAsync('FAIL();'),/service failed/);
  assert.equal(interpreter.execute('return 7;'),7);
  assert.equal(await interpreter.executeAsync('return DOUBLE(3);'),6);
});

test('async methods preserve native this and invoke each side effect once', async () => {
  let calls = 0;
  const object = { value: 4, async read(n: number) { calls++; await Promise.resolve(); return this.value + n; } };
  const interpreter = new InterpreterService({variables:{object}});
  assert.equal(await interpreter.executeAsync('var x=object.read(2); return object.read(x);'),10);
  assert.equal(calls,2);
});

test('rejected array callbacks stop before later elements or statements', async () => {
  const calls: number[] = [];
  const interpreter = new InterpreterService({functions:{async work(n: number) {
    calls.push(n); await Promise.resolve(); if(n===2) throw new Error('stop'); return n;
  }}});
  await assert.rejects(interpreter.executeAsync('[1,2,3].map(n=>work(n));work(4);'),/stop/);
  assert.deepEqual(calls,[1,2]);
});
