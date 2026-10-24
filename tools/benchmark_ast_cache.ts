import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
// Benchmark the compiled package rather than a TS loader's transpilation.
const { AstCache, InterpreterService }: typeof import("../lib/index.js") =
  await import(new URL("../dist/index.js", import.meta.url).href);

const iterations = 1000;
const rounds = 3;
const declarations = Array.from({length:40}, (_,i) => `var value${i}=input+${i};`).join("\n");
const code = `${declarations}\nreturn ${Array.from({length:40},(_,i)=>`value${i}`).join("+")};`;
function measure(enabled: boolean) {
  const cache = new AstCache();
  const interpreter = new InterpreterService({ variables: { input: 0 }, astCache: enabled ? cache : false });
  for (let i=0;i<100;i++) interpreter.execute(code);
  const samples: number[] = [];
  for (let round=0;round<rounds;round++) {
    cache.clear();
    const start = performance.now();
    for (let i=0;i<iterations;i++) {
      interpreter.globalEnv.set("input",i);
      assert.equal(interpreter.execute(code),40*i+780);
    }
    samples.push(performance.now()-start);
  }
  samples.sort((a,b)=>a-b);
  return { medianMs: Number(samples[1].toFixed(2)), stats: enabled ? cache.stats : null };
}
const disabled = measure(false), enabled = measure(true);
assert.equal(enabled.stats!.misses,1);
assert.equal(enabled.stats!.hits,iterations-1);
console.log(JSON.stringify({iterations,rounds,disabled,enabled,speedup:Number((disabled.medianMs/enabled.medianMs).toFixed(2))},null,2));
