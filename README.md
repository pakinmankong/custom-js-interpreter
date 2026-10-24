# custom-js-interpreter

Node.js package สำหรับรัน JavaScript subset ผ่าน AST interpreter พร้อม scope,
closure, array callbacks, formula/data resolver และ custom functions

Source: [kinkop/js-custom-interpreter](https://github.com/kinkop/js-custom-interpreter)

## ติดตั้งจาก GitHub

หลัง push source ขึ้น repo แล้ว ติดตั้งในโปรเจกต์อื่นได้ด้วย:

```sh
npm install git+https://github.com/kinkop/js-custom-interpreter.git
```

ต้องใช้ Node.js 22 ขึ้นไป และ Git สำหรับติดตั้งจาก GitHub
`prepare` จะ build JavaScript และ types ก่อน npm แพ็ก dependency จาก Git
ไม่ต้องติดตั้ง tsx ในแอปที่นำ package ไปใช้
รายละเอียด lifecycle: [npm prepare](https://docs.npmjs.com/cli/v11/using-npm/scripts/#prepare-and-prepublish)

ชื่อ package และชื่อที่ import คือ `custom-js-interpreter`
แม้ชื่อ repository จะเป็น `js-custom-interpreter`
package นี้ใช้ ES modules และมี TypeScript declarations มาด้วย

## ใช้งาน

```ts
import { InterpreterService, createFunctions } from 'custom-js-interpreter';

let interpreter: InterpreterService;
interpreter = new InterpreterService({
  resolver: true,
  variables: {
    DATA: {
      columns: [
        { name: 'A', formula: 'return B + 1' },
        { name: 'B', formula: 'return 10' },
      ],
    },
  },
  functions: createFunctions({
    getEnv: () => interpreter.currentEnv,
    output: (...values) => console.log(...values),
  }),
});

const result = interpreter.execute(`
  const double = value => value * 2;
  print([1, 2, 3].map(double));
  return SUM([1, 2, 3]) + DATA.A;
`);
console.log(result); // 17
```

สำหรับ JavaScript ให้ตัด type annotation `: InterpreterService` ออก
ฟังก์ชันที่ส่งใน context สามารถรับค่าโดยตรง เช่น:

```js
import InterpreterService from 'custom-js-interpreter';

const interpreter = new InterpreterService({
  functions: { DOUBLE: value => value * 2 },
});
console.log(interpreter.execute('return DOUBLE(5);')); // 10
```

## รับ callback จาก print

ส่ง callback ผ่าน `output` เพื่อรับทุกครั้งที่โค้ดเรียก `print(...)`:

```ts
const logs: unknown[][] = [];
const interpreter = new InterpreterService({
  functions: createFunctions({
    output: (...values) => {
      logs.push(values);
      // ส่ง values ไปแสดงใน UI หรือเก็บ log ได้ที่นี่
    },
  }),
});
interpreter.execute('print("items:", [1, 2, 3]); print("done");');
// logs: [["items:", [1, 2, 3]], ["done"]]
```

callback ทำงานแบบ synchronous และได้รับค่าที่ยังไม่แปลงเป็นข้อความ
เมื่อกำหนด `output` จะใช้ callback นี้แทน `console.log`

## String ในข้อมูลและ formula

ค่าเริ่มต้นคือ `resolver: false` อ่าน `variables` เป็นข้อมูลตรง ๆ
โดยไม่ประมวลผล string หรือ `{ formula: "..." }` เป็นโค้ด
เปิด lazy formula resolution ด้วย `new InterpreterService({ resolver: true, variables })`
ใน Dart ใช้ `InterpreterContext(resolver: true, variables: variables)`
กติกา formula ด้านล่างใช้เมื่อเปิด resolver แล้วเท่านั้น

String ทั่วไปใน `variables` เช่น UUID, `"0.1"` หรือ `"Magnetic Flowmeter"`
เป็นข้อมูลตามเดิม ไม่ถูก parse เป็น JavaScript เมื่ออ่าน property
ทั้ง TS และ Dart ใช้กติกาเดียวกัน

รองรับ formula แบบเดิมที่เริ่มด้วยคำสั่ง `return`, `var`, `let`, `const`,
`function`, `if`, `for`, `while`, `do`, `switch`, `try` หรือ `throw`
(มี whitespace, comment หรือ `#CURRENT_ROW` นำหน้าได้)
สำหรับโค้ดรูปแบบอื่น ให้ระบุชัดเจนด้วย `{ formula: "..." }`:

```ts
variables: {
  _UUC_DETAIL_: { unit: 'bd4d74c0-275e-45b5-928b-68fa4f30a505' },
  DATA: {
    A: 'return 10',
    B: { formula: 'return A + 1' },
  },
},
```

String ที่ขึ้นต้นด้วยคำสั่งข้างต้นยังถูกมองเป็น formula เพื่อรองรับข้อมูลเดิม
หากต้องการแยกโค้ดให้ชัดเจน แนะนำให้ใช้ `{ formula: "..." }`

## แสดง error จากโค้ดที่รัน

แปลง error ที่จับได้ด้วย `createInterpreterError` ก่อนส่งให้ formatter:

```ts
import { createInterpreterError, formatInterpreterError } from 'custom-js-interpreter';

try {
  interpreter.execute(code);
} catch (error) {
  const detail = createInterpreterError(
    error, 'script', interpreter.lineOffset, code,
  );
  console.error(formatInterpreterError(detail));
}
```

`lineOffset` หักบรรทัดของ wrapper เพื่อแสดงเลขบรรทัดในโค้ดที่ส่งเข้าไป
ตัวแปลงรองรับทั้งตำแหน่ง syntax error (`loc.line`) และ runtime error
(`loc.start.line`) ส่วนบรรทัด `#CURRENT_ROW` ที่ข้ามยังนับบรรทัดตามเดิม
Error มี `length` สำหรับความยาวช่วงข้อความที่ผิด โดยคำนวณจาก AST span
และใช้ `1` หากไม่มีข้อมูลช่วงตำแหน่ง Formatter จะแสดงเฉพาะ source, เลขบรรทัด
และข้อความ error ส่วน `column`, `position`, `length` ยังอ่านจาก error object ได้
ทั้ง TS และ Dart รองรับ sync/async เหมือนกัน

## Semicolon

โค้ดที่ส่งเข้า interpreter ไม่จำเป็นต้องใส่ `;` ท้าย statement เมื่อจบด้วย
newline, `}` หรือท้ายโค้ด ตามกติกา automatic semicolon insertion ของ JavaScript
ทั้ง TS และ Dart รองรับ เช่น:

```js
const values = [1, 2, 3]
const doubled = values.map(value => value * 2)
return doubled
```

newline ที่ยังต่อ expression ได้จะไม่แยก statement เช่น `.map(...)`, `[index]`
หรือ `(args)` และ expression ของ `return` ต้องเริ่มบรรทัดเดียวกับ `return`
ส่วน `;` สองตัวที่คั่นส่วนต่าง ๆ ใน `for (init; test; update)` ยังต้องใส่

## Public exports

- Default export และ `InterpreterService`
- Types: `InterpreterContext`, `FunctionsOptions`, `FunctionServices`
- `createFunctions`, `matchValue`
- `AstCache`, types `AstCacheStats`, `AstCacheJSON`, `AstJsonValue`
- `Env`, `DataResolver`
- `InterpreterError`, `createInterpreterError`, `formatInterpreterError`

อ่าน signatures และการเชื่อม Standard/Unit services ใน [FUNCTIONS.md](FUNCTIONS.md)
Interpreter ทำงานแบบ synchronous ให้โหลดข้อมูล API/database ก่อน execute

## AST cache (TypeScript)

ค่าเริ่มต้นไม่เก็บ AST cache ต้องส่ง `astCache: new AstCache()` เพื่อเปิดใช้
โดย `new AstCache()` มี LRU cache จำกัด 100 AST
ทั้ง `execute()` และสูตรของ DataResolver ใช้ cache นี้ โดย key เป็น source ที่
ส่งให้ parser จริง รวม wrapper และ whitespace

```ts
import { AstCache, InterpreterService } from 'custom-js-interpreter';

const cache = new AstCache(200);
const interpreter = new InterpreterService({
  astCache: cache,
  variables: { input: 1 },
});

interpreter.execute('return input + 1;'); // 2, parse ครั้งแรก
interpreter.globalEnv.set('input', 9);
interpreter.execute('return input + 1;'); // 10, reuse AST และประเมินใหม่
console.log(cache.stats); // hits: 1, misses: 1, size: 1
interpreter.clearAstCache(); // ล้าง AST และ reset counters
```

ไม่ส่ง `astCache` หรือส่ง `astCache: false` เพื่อปิด cache หรือส่ง `AstCache`
ตัวเดียวกันให้หลาย interpreter เพื่อแชร์ AST ได้ โดยยังแยก scope และค่าตัวแปร
Cached AST ถูก freeze ทั้งต้นไม้ รวม AST ที่ได้จาก public `parse()` เพื่อป้องกัน
การแก้ node แล้วกระทบการรันครั้งถัดไป ส่วน syntax error จะไม่ถูกเก็บใน cache

นี่คือ **AST cache** ไม่ใช่ cache ผลลัพธ์หรือ closure การรันแต่ละครั้งยังสร้าง
ค่าต่าง ๆ และเรียก host functions ใหม่ตามปกติ ส่วน formula result cache เดิมของ
DataResolver ยังมีอยู่แยกต่างหาก หากเปลี่ยนข้อมูลต้นทางและต้องการคำนวณสูตรใหม่
ให้ใช้ `interpreter.dataResolver.clearCache()` การล้าง AST อย่างเดียวไม่ล้างผลสูตร
และการ clear cache ที่แชร์กันจะล้าง AST ให้ทุก instance ที่ใช้ cache นั้น

รันทดลองด้วย `npm run benchmark:ast-cache` ซึ่ง build แล้ววัดเวลารันโค้ดเดิม
1,000 ครั้ง (median 3 รอบ) เทียบเปิด/ปิด cache โดยเปลี่ยน input ทุกครั้งและตรวจ
ผลลัพธ์ด้วย ประสิทธิภาพที่ได้ขึ้นกับโค้ดและเครื่อง หาก result cache ของสูตร hit
อยู่แล้ว สูตรนั้นจะไม่ถึงขั้น parse จึงไม่ได้ประโยชน์เพิ่มจาก AST cache ในครั้งนั้น

### ส่ง AST cache เป็น JSON ไป Flutter

```ts
const interpreter = new InterpreterService({ astCache: new AstCache() });
interpreter.compile('return SUM([1, 2, 3]);'); // เตรียม AST โดยไม่รันโค้ด
const payload = interpreter.exportAstCache();
const json = JSON.stringify(payload); // ส่งผ่าน API หรือเขียนลงไฟล์ได้
// หรือ JSON.stringify(interpreter.astCache) จะเรียก toJSON() เช่นกัน
```

เรียก `exportAstCache()` หลัง `execute()` ได้ด้วย แต่ snapshot จะมีเฉพาะ source
ที่เคย parse และยังอยู่ใน LRU เท่านั้น ถ้ามีสูตรที่ต้องใช้ใน Flutter แต่ฝั่ง TS
ยังไม่เคยรัน ให้เรียก `compileFormula(formula)` ก่อน export ปรับ capacity ให้
มากพอสำหรับ main entry และสูตรทั้งหมด เพื่อไม่ให้ entry ที่ต้องใช้ถูก evict

ตัวอย่าง Flutter/Dart:

```dart
final bundle = CompiledAstBundle.decode(jsonFromServer);
final interpreter = InterpreterService(InterpreterContext(
  astBundle: bundle,
  requireCachedAst: true,
  functions: createFunctions(),
));
final result = interpreter.executeCached(); // 6; ไม่ parse JS ซ้ำ
```

หาก bundle มี main หลายตัว ให้ส่งโค้ดที่ต้องการเป็น argument ของ
`executeCached(code)` หรือใช้ `execute(code)` ตามเดิม โหมด `requireCachedAst`
จะแจ้ง error ถ้า main/formula source ไม่อยู่ใน bundle แทนการ parse เพิ่ม
ถ้าปิดโหมดนี้ source ที่ขาดจะ fallback ไป Dart parser เดิม

JSON มี `format`, `version`, `parser` และ `entries: [{source, ast}]`
ไม่รวมตัวแปร, host functions, ผลลัพธ์ หรือ closure ต้องส่ง variables/functions
ให้ Dart runtime เอง AST BigInt และ nonfinite numbers ถูกแปลงให้ส่งผ่าน JSON ได้
ตัวอ่าน Dart ตรวจ version และปรับ Babel AST เป็นรูปแบบที่ evaluator ใช้ได้
นี่คือการ **ประเมิน AST ตอน runtime** ไม่ใช่ compile JavaScript เป็น native code
Dart เพิ่มเฉพาะตัวอ่าน snapshot นี้ ยังไม่ได้เพิ่ม LRU cache ให้ Dart parser

สร้างไฟล์ JSON โดยไม่รัน JS:

```sh
npm run export:ast -- dart/code.js /tmp/ast-cache.json
# เพิ่มสูตรที่ต้องใช้ โดยแต่ละไฟล์มีข้อความสูตรตรงกับใน data source:
npm run export:ast -- code.js /tmp/ast-cache.json formula-a.js formula-b.js
npm run test:ast-json # เทียบ TS กับ Dart ที่ใช้ JSON โดยห้าม parse source ซ้ำ
```

ตัวอย่าง JSON อยู่ใน `dart/ast_cache_example.json` และวิธีใช้เพิ่มเติมอยู่ใน
[Dart README](https://github.com/kinkop/js-custom-interpreter/blob/main/dart/README.md)

## พัฒนาและตรวจ package

```sh
npm install
npm run build
npm run typecheck
npm test
npm run test:package
npm pack
```

`lib/index.ts` เป็น library entry point ส่วน `index.ts` ที่ root เป็นตัวอย่าง
รันด้วย `npm run example` โดยการ import package จะไม่รันตัวอย่างนี้

`npm pack` สร้าง tarball ที่มีเฉพาะ dist, types, license และเอกสาร
ไม่รวม tests, development tools, source ตัวอย่าง หรือ Dart
ทดสอบ tarball ในโปรเจกต์อื่นได้ด้วย:

```sh
npm install /path/to/custom-js-interpreter-1.0.0.tgz
```

GitHub Actions ตรวจ Node package บน Node 22 และ 24 เมื่อ push หรือเปิด PR
ไม่มี workflow สำหรับ publish โดยอัตโนมัติ การเผยแพร่บน npm registry
ต้องเลือกชื่อที่มีสิทธิ์ใช้งานและตั้งค่า npm account แยกต่างหาก

## Dart / Flutter และขอบเขตภาษา

Dart อยู่ใน `dart/` ใน source repository และใช้เป็น Flutter path dependency
ได้ตาม [Dart README](https://github.com/kinkop/js-custom-interpreter/blob/main/dart/README.md)
โดยไม่ต้องใช้ Node.js หรือ package ฝั่ง npm ตอนรัน Flutter

นี่เป็น JavaScript subset ยังไม่รองรับ ECMAScript ทั้งหมด เช่น class/new,
async/await และ try/catch

อ่านขอบเขตการเทียบ TS/Dart ใน [PARITY.md](PARITY.md)
สำหรับผู้พัฒนาที่มี Dart SDK รันเทียบทั้งสองฝั่งด้วย `npm run test:parity`

License: ISC

## Async custom functions

ใช้ `await interpreter.executeAsync(code)` เมื่อต้องเรียก custom function ที่คืน
Promise เช่น query database หรือเรียก service โดย interpreter จะรอผลตามลำดับ
ก่อนประเมิน expression และ statement ถัดไป โค้ดที่ส่งเข้าไปเขียนเหมือนเดิม
ไม่ต้องใส่ `await` ใน script:

```ts
import { InterpreterService, createFunctions } from 'custom-js-interpreter';

const interpreter: InterpreterService = new InterpreterService({
  variables: data,
  functions: {
    ...createFunctions({ getEnv: () => interpreter.currentEnv }),
    FIND_STD_ERROR: async (standardId, lookupValue) => {
      return await myService.findStdError(standardId, lookupValue);
    },
  },
});

try {
  const result = await interpreter.executeAsync(`
    var row = FIND_STD_ERROR(standardId, lookupValue)
    return row.uncertainty
  `);
} catch (error) {
  console.error(formatInterpreterError(createInterpreterError(
    error, 'script', interpreter.lineOffset, interpreter.userCode,
  )));
}
```

Async mode รอผลใน loop, condition, function, template และ callback ของ array
(`map`, `filter`, `forEach`, `reduce`, `sort`, `some`, `every`, `find`, `findIndex`)
รวมถึง string `replace` และ `GOAL_SEEK` โดย callback ของ array ทำงานตามลำดับ
หากเปิด `resolver: true` จะรอ formula dependencies ด้วย และใช้ AST cache เดิมได้

`execute()` ยังเป็น synchronous ตามเดิม ให้ใช้ `executeAsync()` สำหรับ async
custom functions โดยตรง ส่วน providers ใน `createFunctions({ services: ... })`
ยังเป็น synchronous ให้ override ฟังก์ชันที่ต้องเรียก async service ตามตัวอย่าง
Custom host functions ที่เรียก callback จาก script ต้องรอ callback นั้นด้วย
หากถือ interpreter function โดยตรง ใช้ `await interpreter.callFunctionAsync(fn, args)`

ใช้ interpreter หนึ่ง instance สำหรับหนึ่ง execution ในแต่ละขณะ
การเรียก `execute()` หรือ `executeAsync()` ซ้อนระหว่างที่ async execution ยังไม่จบ
จะแจ้ง error ให้แยก instance หากต้องการรันพร้อมกัน
