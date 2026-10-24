// Refresh fixtures after changing tests/basic_cases.json or index.ts. Run from the repository root.
import fs from 'node:fs';
import vm from 'node:vm';
import { parse } from '@babel/parser';
fs.copyFileSync('tests/async_cases.json', 'dart/async_cases.json');
const fixtures = JSON.parse(fs.readFileSync('tests/basic_cases.json', 'utf8'));
fs.writeFileSync('dart/test_cases.json', JSON.stringify(fixtures, null, 2) + '\n');
// Copy the example data and interpreted code without copying host JS functions.
const index = fs.readFileSync('index.ts', 'utf8');
const indexAst = parse(index, { sourceType: 'module', plugins: ['typescript'] });
function walk(node) {
  if (!node || typeof node !== 'object') return;
  if (node.type === 'NewExpression' && node.callee.name === 'InterpreterService') {
    const variables = node.arguments[0].properties.find(p => p.key.name === 'variables').value;
    fs.writeFileSync('dart/example_data.json', JSON.stringify(vm.runInNewContext('(' + index.slice(variables.start, variables.end) + ')'), null, 2) + '\n');
  }
  if (node.type === 'CallExpression' && node.callee.object?.name === 'interpreter' && node.callee.property?.name === 'execute') {
    fs.writeFileSync('dart/example_code.js', node.arguments[0].quasis[0].value.cooked.trim() + '\n');
  }
  for (const v of Object.values(node)) if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === 'object') walk(v);
}
walk(indexAst);
console.log(`Exported ${fixtures.length} fixtures`);
