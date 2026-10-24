import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import InterpreterService from "../lib/interpreter_service.js";
import { createFunctions } from "../lib/functions.js";

const transferAst = process.argv.includes("--ast-json");
const exportedCaches: any[] = [];
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (name: string) => JSON.parse(fs.readFileSync(path.join(root, name), "utf8"));
const cases = [
  ...read("tests/basic_cases.json").map((v: any) => ({ ...v, group: "basic" })),
  ...read("dart/function_test_cases.json").map((v: any) => ({ ...v, group: "functions" })),
  ...read("tests/parity_cases.json").map((v: any) => ({ ...v, group: "extended" })),
];
function encode(value: any): any {
  if (value === undefined) return { $undefined: true };
  if (typeof value === "number" && !Number.isFinite(value)) return { $number: String(value) };
  if (typeof value === "bigint") return { $bigint: String(value) };
  if (typeof value === "function") return { $function: true };
  if (Array.isArray(value)) return Array.from(value, encode);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k,v]) => [k,encode(v)]));
  return value;
}
function run(fixture: any) {
  const calls: any[][] = [];
  let interpreter: InterpreterService;
  const functions = createFunctions({
    getEnv: () => interpreter.currentEnv,
    output: (...values) => { calls.push(values); },
    services: {
      getStandardErrors: id => id === 1 ? [{value:20,uncertainty:5},{value:10,uncertainty:2},{value:30,uncertainty:1}] : [],
      getUnitById: id => id === 2 ? {unit_id:2,unit_short_name_en:"cm",unit_name_en:"centimetre"} : null,
      getUnitByName: name => name === "metre" ? {unit_id:1} : null,
      convertUnit: (from,to,value) => from===1 && to===2 ? value*100 : null,
    },
  });
  Object.assign(functions, {
    HOST_ADD: (a: number,b: number) => a+b,
    HOST_APPLY: (fn: (x: number)=>any,value: number) => fn(value),
    HOST_IDENTITY: (fn: any) => fn,
  });
  interpreter = new InterpreterService({
    variables: {CURRENT_ROW:[1,0],_UNIT_:{1:{ID:1,SYMBOL:"m",NAME:"metre"}},...fixture.variables}, functions,
  });
  try { return {status:"ok", value:encode(interpreter.execute(fixture.code)), calls:encode(calls)}; }
  catch (error: any) { return {status:"error", error:String(error.message ?? error), calls:encode(calls)}; }
  finally { if (transferAst) exportedCaches.push(interpreter.exportAstCache()); }
}
function equivalent(a: any, b: any, tolerance: number): boolean {
  if (typeof a === "number" && typeof b === "number") return Math.abs(a-b) <= tolerance;
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object") return false;
  const keys=Object.keys(a), other=Object.keys(b);
  return keys.length===other.length && keys.every(key => Object.hasOwn(b,key) && equivalent(a[key],b[key],tolerance));
}
const originalLog=console.log;
console.log=()=>{};
const tsResults = cases.map(run);
console.log=originalLog;
const inputs = transferAst ? cases.map((fixture:any,i:number) => ({...fixture,astCache:exportedCaches[i]})) : cases;
const child=spawnSync("dart",[path.join(root,"dart/tool/parity_runner.dart")],{input:JSON.stringify(inputs),encoding:"utf8",maxBuffer:16*1024*1024});
if(child.status!==0){process.stderr.write(child.stderr||child.stdout);process.exit(child.status??1);}
const dart=JSON.parse(child.stdout);
let passed=0;
const failures: any[]=[];
for(let i=0;i<cases.length;i++){
  const fixture=cases[i],ts=tsResults[i],other=dart[i];
  let ok=ts.status===other.status && equivalent(ts.calls,other.calls,1e-10);
  if(fixture.error){ok=ok&&ts.status==="error"&&new RegExp(fixture.error).test(ts.error!)&&new RegExp(fixture.error).test(other.error);}
  else if(ts.status==="error"){ok=false;}
  else if(fixture.check==="RAND"||fixture.check==="RANDBETWEEN"){
    const valid=(v:any)=>typeof v==="number"&&Number.isFinite(v)&&(fixture.check==="RAND"?v>=0&&v<1:Number.isInteger(v)&&v>=2&&v<=5);
    ok=ok&&valid(ts.value)&&valid(other.value);
  }else{ok=ok&&equivalent(ts.value,other.value,fixture.tolerance??1e-10);}
  if(ok)passed++;else failures.push({group:fixture.group,name:fixture.name,code:fixture.code,ts,dart:other});
}
console.log=originalLog;
console.log(JSON.stringify({mode:transferAst ? "ast-json" : "source",total:cases.length,passed,failed:failures.length,groups:Object.fromEntries(["basic","functions","extended"].map(group=>[group,cases.filter((c:any)=>c.group===group).length])),failures},null,2));
if(failures.length)process.exitCode=1;
