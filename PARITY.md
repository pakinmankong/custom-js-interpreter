# TypeScript / Dart parity audit

The direct comparison currently passes **345/345 cases**:

| Area | Cases |
| --- | ---: |
| Shared basic syntax, scope and optional-semicolon fixtures | 61 |
| All 51 formula functions plus print, edge/error cases and TINV grid | 162 |
| Extended runtime, host callback and DataResolver cases | 122 |

Each case uses the same JS source and predefined data in both interpreters.
Standard/Unit providers use equivalent in-memory data, with no network requests.
A new interpreter is created per case. The comparison checks return values and
captured print arguments. Expected failures must occur on both sides and match
the same error pattern. Unexpected errors on either side fail the comparison.

```sh
npx tsx tools/check_parity.ts
npx tsx --test testing.ts
dart dart/testing.dart
dart analyze dart
```

Separate regression suites pass 247 TS tests and 242 Dart tests. Their counts
are different because some platform-specific setup/validation tests are separate;
the direct comparison above executes exactly the same 345 input cases on both.
The library smoke test also compiles/runs as Dart native and Dart-to-JS.

## Covered behavior

- var/let/const, reassignment, shadowing, closures, parameters/default/rest,
  function hoisting, method this and arrow lexical this.
- for, for-of, for-in, while, do-while, break/continue, if/else, ternary,
  logical short circuit, assignment and arithmetic/comparison operators.
- Arrays/objects, spreads, computed properties, native callback methods,
  deleted array entries, length changes, index spelling, object key order.
- String positions, regex split/capture groups, regex state, string replacement
  tokens and callbacks, Unicode indexing/spread, nested/escaped templates.
- Primitive equality/coercion, binary/octal/hex strings, large Number precision,
  BigInt arithmetic/type errors and 32-bit bitwise negation.
- All registered formula functions, including optional/default parameters,
  row context, matrix inverse/multiply, goal seek and Standard/Unit adapters.
- Host-provided functions, callbacks with block returns/closures and a callback
  returned from a host function.
- DataResolver forward references, named arrays/indexes, columns object/array,
  children, RECORDS alias, computed paths, caching and circular/missing references.

The audit found and corrected differences in the Dart runtime/parser, including
null/boolean equality, radix conversion, zero BigInt truthiness, Number formatting
and precision, nested templates, sparse arrays, property order and string/regex
arguments/callbacks. Shared basic fixtures now have a durable source in
`tests/basic_cases.json`; the exporter no longer depends on the function table
replacing the old basic tests in testing.ts.

## Interpretation and limits

Passing these cases establishes agreement for the tested language subset. It is
not proof of equivalence for arbitrary JavaScript. Both interpreters retain the
project's custom scope semantics (ordinary blocks do not introduce lexical scope,
no complete var hoisting/TDZ). Native host APIs have different adapter types:
Dart uses NativeFunction for variadic calls/callback bridging.

- Numeric comparisons use absolute tolerance 1e-10 by default. TINV/GOAL_SEEK use
  explicit case tolerances; the TINV grid allows max(1e-6, abs(expected)*1e-7).
- RAND/RANDBETWEEN are checked for their range/integer contracts, not identical
  random samples. No random seed is shared between runtimes.
- Error **patterns and success/failure behavior** are compared. Exact error class,
  message, stack trace and source-coordinate equality are not guaranteed.
- This does not provide full ECMAScript constructors, prototypes, property
  descriptors, arbitrary native array/string methods, regex d/named-group
  replacement semantics, async/await or Promise/Future evaluation. See the
  Dart README for syntax boundaries. In particular, TS can access more host
  JavaScript methods/prototypes than the explicit Dart runtime exposes.
- Flutter device integration is not part of this audit; native and web library
  compilation/smoke tests run without a Flutter application build.

## Refreshing cases

Edit the tables in testing.ts, tests/basic_cases.json or tests/parity_cases.json.
Refresh the generated Dart snapshots with:

```sh
node dart/tool/export_fixtures.mjs
node dart/tool/export_function_fixtures.mjs
```

`tools/check_parity.ts` orchestrates the Node/TS run and Dart subprocess.
`dart/tool/parity_runner.dart` is a development CLI and is not needed in Flutter.

## AST JSON transfer

`npm run test:ast-json` runs the same 345 cases after executing on TS and exporting
its versioned AST cache. Dart receives that JSON, with source parsing disabled by
`requireCachedAst: true`. Results, captured outputs and expected error patterns
are compared as in source mode. This also verifies formula entries, Babel
BigInt/RegExp/template nodes, nonfinite literal encoding and host callbacks.
This is AST interpretation, not AOT compilation of the embedded JS.
