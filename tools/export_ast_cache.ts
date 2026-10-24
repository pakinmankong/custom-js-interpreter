import fs from "node:fs";
import { AstCache, InterpreterService } from "../lib/index.js";

const [input, output, ...formulaFiles] = process.argv.slice(2);
if (!input || !output) {
  console.error("Usage: npm run export:ast -- <code.js> <output.json> [formula.js ...]");
  process.exit(1);
}
// No evaluation: inputs/functions need only be provided by the receiving runtime.
const interpreter = new InterpreterService({astCache:new AstCache(Math.max(100,formulaFiles.length+1))});
interpreter.compile(fs.readFileSync(input,"utf8"));
for(const file of formulaFiles) interpreter.compileFormula(fs.readFileSync(file,"utf8"));
fs.writeFileSync(output,JSON.stringify(interpreter.exportAstCache(),null,2)+"\n");
console.log(`Exported ${interpreter.astCache!.stats.size} AST entries to ${output}`);
