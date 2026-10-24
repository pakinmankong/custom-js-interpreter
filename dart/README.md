# Custom JS interpreter — Dart

Pure Dart port of the TypeScript interpreter. The library does not require Node,
Babel, JavaScript interop, Flutter plugins, or third-party Dart dependencies.
JavaScript source strings are interpreted at runtime; the Dart interpreter itself
can be compiled with Flutter.

## Files

| TypeScript                   | Dart                                                                      |
| ---------------------------- | ------------------------------------------------------------------------- |
| `lib/interpreter_service.ts` | `lib/interpreter_service.dart`                                            |
| `lib/data_resolver.ts`       | `lib/data_resolver.dart`                                                  |
| `lib/env.ts`                 | `lib/env.dart`                                                            |
| `lib/errors.ts`              | `lib/errors.dart`                                                         |
| `lib/functions.ts`          | `lib/functions.dart`, `lib/base_functions.dart`, `lib/statistics.dart` |
| `testing.ts`                 | `function_testing.dart`, `function_test_cases.json` |
| `index.ts`                   | `index.dart`, `lib/builtins.dart`, `example_data.json`, `example_code.js` |
| `testing.ts`                 | `testing.dart`, `test_cases.json`                                         |

`parser.dart` replaces Babel with a subset parser. `runtime.dart` implements
JavaScript values, coercion, native functions, and array/string methods in Dart.
`custom_js_interpreter.dart` is the public library entry point.

## Run (from repository root)

For a scratchpad, edit the JavaScript in `code.js`, then
run `dart dart/code.dart`. The runner reads `code.js` beside itself, regardless
of the working directory. Add input data in `variables` in `code.dart`; print and the example
math functions are already registered. Errors show the line in the JS string.

```sh
dart dart/code.dart
dart dart/code.dart --code path/to/code.js
dart dart/code.dart --ast dart/ast_cache_example.json
dart dart/code.dart --ast dart/ast_cache_example.json --strict
dart dart/testing.dart
dart dart/index.dart
dart analyze dart
node dart/tool/export_fixtures.mjs  # Refresh snapshots after editing TypeScript tests/example
node dart/tool/export_function_fixtures.mjs  # Refresh the shared testing.ts function cases
```

Basic cases live in `tests/basic_cases.json`; the fixture exporter copies them
to the Dart snapshot and refreshes the index example. Function tables are exported
from `testing.ts` by `export_function_fixtures.mjs`. Host print tests and
resolver/error coverage are also exercised directly by `testing.dart`. Exporters
are development tools, not general TypeScript translators.

## Flutter

Add a local path dependency in the Flutter application's `pubspec.yaml`:

```yaml
dependencies:
  custom_js_interpreter:
    path: ../custom-js-interpreter/dart
```

```dart
import 'package:custom_js_interpreter/custom_js_interpreter.dart';

final interpreter = InterpreterService(InterpreterContext(
  functions: {
    'print': NativeFunction((args, thisValue) {
      print(args.map(jsString).join(' '));
      return undefined;
    }),
  },
));
final result = interpreter.execute('''
  const double = value => value * 2;
  const values = [1, 2, 3].map(double);
  print(values);
  return values;
'''); // [2, 4, 6]
```

`NativeFunction` receives the complete argument list and receiver. To invoke a
callback supplied by interpreted code, use
`interpreter.callFunction(args[0], [value, index], thisValue)` inside your native
function. Fixed-arity Dart functions can also be placed in `context.functions`;
`Function.apply` invokes them. Use `NativeFunction` for variadic arguments or
callbacks, rather than depending on Dart reflection.

The `undefined` singleton is distinct from Dart `null`; use
`identical(value, undefined)` when inspecting results. `createExampleFunctions`
in `lib/builtins.dart` remains a compatibility wrapper for `createFunctions()`.
Both now register all 51 formula functions plus print.
The CLI example uses `dart:io`; the public library does not.

## Formula functions and services

`createFunctions()` is exported by the public library. JavaScript parameters have
same order/defaults as TypeScript; see [the function reference](../FUNCTIONS.md).
`code.dart` and `index.dart` already register the full set.

```dart
late final InterpreterService interpreter;
interpreter = InterpreterService(InterpreterContext(
  variables: {
    'CURRENT_ROW': [0],
    '_UNIT_': {'1': {'ID': 1, 'SYMBOL': 'm', 'NAME': 'metre'}},
  },
  functions: createFunctions(
    getEnv: () => interpreter.currentEnv,
    output: (values) => print(values.map(jsString).join(' ')),
    services: FunctionServices(
      getStandardErrors: (id) => id == 1
        ? [{'value': 10, 'uncertainty': 2}, {'value': 20, 'uncertainty': 5}]
        : [],
      // getUnitById: (id) => cachedUnits[id],
      // getUnitByName: (name) => cachedUnitsByName[name],
      // convertUnit: (from, to, value) => ...,
    ),
  ),
));
final result = interpreter.execute('return FIND_STD_ERROR(1, 15);');
```

Standard/Unit providers read preloaded data synchronously. Fetch API/database data
before `execute()`; providers returning Future are rejected. Missing services
produce a configuration error. `UNIT` checks `_UNIT_` first. `getEnv` enables the
current function's CURRENT_ROW and unit cache.

`TINV` uses a pure Dart adaptation of jStat's Student t/incomplete beta routines,
with the MIT attribution in `JSTAT_LICENSE`. Numerical parity tests use explicit
floating-point tolerances (at least 1e-6 for the TINV grid), rather than exact
bit-for-bit comparison. No JavaScript package is needed in
Flutter. Matrix and GOAL_SEEK implementations are also pure Dart.

`dart/testing.dart` includes `function_testing.dart`, which runs shared cases
from `testing.ts`, a TINV parity grid, and additional callback/service tests.
Fixture exporters are development tools and are not needed in a Flutter app.

## Compatibility boundaries

This is the project's custom language subset, not a complete ECMAScript engine.
The current scope behavior follows the TypeScript interpreter: ordinary blocks
do not create lexical scopes, var declarations are not fully hoisted, and there
is no temporal dead zone. Const bindings reject writes; object/array contents
remain mutable. Arrow functions inherit lexical `this`. For-of/in let/const
bindings have separate iteration environments.

Supported syntax includes variables, functions, arrows, default/rest parameters,
return, if/else, loops, break/continue, arrays/objects, spread, member access,
optional properties, assignment, arithmetic/comparison/logical expressions,
ternaries, BigInt literals, simple template interpolation and basic regex literals.

Array methods include push/pop/shift/unshift/splice/slice, map/filter/reduce/
forEach/sort, reverse/join/concat, includes/indexOf/find/findIndex/some/every.
Methods are explicitly implemented; arbitrary JS prototype methods or Dart object
members are not automatically exposed. Data sources should be Maps and Lists.

Known differences from Babel/native JavaScript:

- No classes, constructors/new, switch, try/catch/throw, async/await, generators,
  destructuring, object method shorthand, or optional function calls. These are
  also outside the original evaluator's implemented node set.
- `instanceof` reports an explicit error because Dart types are not JS constructors.
- Template interpolation supports nested object expressions, quoted braces,
  escaped interpolation and nested template strings. Regex supports i/m/s/u/g/y
  flags, stateful test/exec, and string replace/split. Regex d indices, named
  replacement groups and complete JS RegExp/prototype semantics remain unsupported.
- Array-expression holes become undefined, matching the TS evaluator. Holes
  created by delete/length expansion are tracked separately for property checks
  and callback methods. Arbitrary prototype behavior is not emulated.
- Coercion covers common primitive cases, not full ECMAScript ToPrimitive,
  property descriptors, prototypes, or Symbol behavior. Host callbacks use the
  explicit NativeFunction/callFunction API above.
- Example math helpers preserve common numeric results, but Dart numeric/string
  formatting and validation messages can differ at edge cases from JS.

The CLI and smoke tests check Dart VM behavior; a full Flutter device build is a
separate integration step in the consuming Flutter application.

## Direct TS/Dart parity check

Run `npx tsx tools/check_parity.ts` from the repository root. It executes the
same basic, formula-function and extended cases in both interpreters and compares
results, captured print calls and expected errors. See [PARITY.md](../PARITY.md)
for the verified scope and remaining differences.

## รับ AST cache JSON จาก TypeScript

ฝั่ง TS ใช้ `compile(code)` / `compileFormula(formula)` โดยไม่รัน JS หรือเรียก
`execute(code)` ตามเดิม แล้วส่ง `JSON.stringify(interpreter.exportAstCache())`
ไปให้ Flutter รูปแบบ snapshot มี version และ entries ที่ประกอบด้วย source/AST

```dart
final bundle = CompiledAstBundle.decode(jsonFromServer);
late final InterpreterService interpreter;
interpreter = InterpreterService(InterpreterContext(
  astBundle: bundle,
  requireCachedAst: true,
  variables: {'input': 10},
  functions: createFunctions(getEnv: () => interpreter.currentEnv),
));
final result = interpreter.executeCached();
```

ถ้า JSON ถูก decode มาแล้ว ใช้ `CompiledAstBundle.fromJson(decodedObject)`
`executeCached()` ใช้ main entry เดียวใน bundle โดยไม่ต้องมีไฟล์ JS แยก ถ้ามี
main หลายตัวให้ใช้ `executeCached(exactCode)` การเรียก `execute(exactCode)` และ
สูตรใน DataResolver ก็ใช้ AST จาก bundle ได้เช่นกัน Source รวม whitespace
ต้องตรงกับที่ TS compile ไว้

`requireCachedAst: true` ห้าม fallback ไป parse JS หาก entry ขาดจะได้ AST cache
miss สูตรใน branch ที่ฝั่ง TS ยังไม่รันต้อง compileFormula ไว้ล่วงหน้า และตั้ง
capacity ของ AST cache ฝั่ง TS ให้พอสำหรับ main/formulas ที่ต้องส่ง หากไม่ได้
เปิด strict mode จะ fallback ไป parser เดิมได้

ตัวแปร, host functions, result cache และ closure ไม่อยู่ใน JSON ต้องเตรียมที่
Flutter เองเหมือนการใช้ interpreter ปกติ Imported AST เป็น read-only และไม่
ใช่ Dart LRU parser cache ตัวรับรองรับเฉพาะ AST node types ที่ evaluator รองรับ
และ JSON version/parser ที่รู้จัก จะปฏิเสธ schema version อื่น

JSON ใช้เป็นข้อมูลสำหรับประเมิน AST ตอน runtime ไม่ใช่การ compile JavaScript
เป็น Flutter native code ไลบรารีตัวอ่านเป็น pure Dart ใช้ได้ทั้ง native/web

ทดสอบส่ง AST ข้ามภาษาจริงด้วย `npm run test:ast-json` จาก repository root
ใช้ JSON เดินทางจาก TS ไป Dart และเปิด strict mode ในทุก case

## เลือกโหมดจากตัวรันทดลอง

- `dart dart/code.dart`: อ่าน `dart/code.js` แล้ว parse ด้วย Dart ตามเดิม
- `dart dart/code.dart --code path/to/code.js`: เลือกไฟล์ JS อื่น
- `dart dart/code.dart --ast path/to/cache.json`: รัน main จาก AST JSON โดยตรง
- `dart dart/code.dart --ast path/to/cache.json --code path/to/code.js`: ใช้ AST
  เมื่อ source ตรงกับใน bundle ถ้าไม่พบจะ parse ด้วย Dart
- เพิ่ม `--strict` เมื่อใช้ `--ast` เพื่อห้าม parse ทั้ง main และสูตร หาก AST ขาด
  จะแจ้ง cache miss

Path ที่ส่งด้วย flags อ้างอิง working directory; เฉพาะ `code.js` ค่าเริ่มต้น
อ้างอิงตำแหน่งสคริปต์ หาก bundle มี main หลายรายการให้ใช้ `--code` เลือก
รัน `dart dart/code.dart --help` เพื่อดูคำสั่ง และแก้ predefined variables หรือ
services ใน `code.dart` เหมือนเดิม

สำหรับ Flutter ไม่ต้องใช้ CLI นี้ ใช้ `InterpreterContext(astBundle: bundle)`
แล้ว `execute(code)` ได้ทั้ง cached AST และ fallback parser; หากไม่มี bundle
จะ parse source เองตามปกติ ใช้ `executeCached()` เมื่อต้องการเลือก main จาก JSON

## ไม่บังคับ semicolon ท้าย statement

รองรับการจบ statement ด้วย newline, `}` หรือท้ายโค้ด ตาม JavaScript ASI ทั้ง
LF, CRLF, CR และ Unicode line separators ใช้งานได้โดยไม่ต้องเติม `;` ทุกบรรทัด
newline ไม่ได้แยก statement เสมอไป เช่น method chain, array access หรือ function
call ที่ต่อจาก expression ก่อนหน้า และ `return` ที่ขึ้นบรรทัดใหม่ก่อน expression
จะคืน undefined ส่วน separators ใน `for (init; test; update)` ยังต้องใส่
