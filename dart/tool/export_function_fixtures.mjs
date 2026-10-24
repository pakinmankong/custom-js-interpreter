// Run from the repository root after editing testing.ts.
import fs from 'node:fs';
import vm from 'node:vm';
import { parse } from '@babel/parser';
import jStat from 'jstat';
const source = fs.readFileSync('testing.ts', 'utf8');
const ast = parse(source, { sourceType: 'module', plugins: ['typescript'] });
const encode = value => value === undefined ? { $undefined: true } :
  typeof value === 'number' && !Number.isFinite(value) ? { $number: String(value) } :
  Array.isArray(value) ? value.map(encode) : value && typeof value === 'object' ?
  Object.fromEntries(Object.entries(value).map(([key, v]) => [key, encode(v)])) : value;
const fixtures = [];
for (const statement of ast.program.body) {
  if (statement.type !== 'VariableDeclaration') continue;
  const declaration = statement.declarations[0];
  const name = declaration.id.name;
  if (!['cases', 'edgeCases', 'errors'].includes(name)) continue;
  let expression = source.slice(declaration.init.start, declaration.init.end);
  const annotations = [];
  function collectAnnotations(node) {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'TSTypeAnnotation') { annotations.push(node); return; }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach(collectAnnotations);
      else if (value && typeof value === 'object') collectAnnotations(value);
    }
  }
  collectAnnotations(declaration.init);
  for (const annotation of annotations.sort((a, b) => b.start - a.start)) {
    const start = annotation.start - declaration.init.start;
    const end = annotation.end - declaration.init.start;
    expression = expression.slice(0, start) + expression.slice(end);
  }
  const entries = vm.runInNewContext(expression);
  for (const [label, expression, expected] of entries) {
    const fixture = { name: label, code: `return ${expression};` };
    if (name === 'errors') fixture.error = expected.source;
    else if (typeof expected === 'function') {
      fixture.check = label;
      if (label === 'TINV') { fixture.expected = 2.2281388519649385; fixture.tolerance = 1e-6; }
      if (label === 'GOAL_SEEK') { fixture.expected = 5; fixture.tolerance = 1e-6; }
    } else fixture.expected = encode(expected);
    fixtures.push(fixture);
  }
}
// Numerical parity across central and tail probabilities, using the TS jStat backend.
for (const probability of [0.5, 0.05, 0.001, 1e-6]) {
  for (const df of [1, 2, 10, 30, 100]) {
    const expected = jStat.studentt.inv(1 - probability / 2, df);
    fixtures.push({ name: `TINV grid p=${probability} df=${df}`, code: `return TINV(${probability}, ${df});`, check: 'TINV', expected, tolerance: Math.max(1e-6, Math.abs(expected) * 1e-7) });
  }
}
fs.writeFileSync('dart/function_test_cases.json', JSON.stringify(fixtures, null, 2) + '\n');
console.log(`Exported ${fixtures.length} function fixtures`);
