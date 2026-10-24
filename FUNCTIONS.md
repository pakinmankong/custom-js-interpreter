# Formula functions

`index.ts` registers all 51 functions from the supplied reference, plus `print`.
Implementations live in `lib/functions.ts` and accept evaluated parameters
normally, e.g. `FIRST([1, 2])`, rather than reading `node.arguments`.
Both TS and Dart interpreters remain synchronous. Dart registers the same set
through `createFunctions()` in `dart/lib/functions.dart`; `createExampleFunctions()`
is a compatibility wrapper. See [Dart usage](dart/README.md) for service wiring.

## Registration

```ts
import { InterpreterService, createFunctions } from 'custom-js-interpreter';

const standardErrors: Record<string, Record<string, any>[]> = {
  '1': [{ value: 10, uncertainty: 2 }, { value: 20, uncertainty: 5 }],
};
let interpreter: InterpreterService;
interpreter = new InterpreterService({
  variables: {
    CURRENT_ROWS: [0, 0],
    _UNIT_: { '1': { ID: 1, SYMBOL: 'm', NAME: 'metre' } },
  },
  functions: createFunctions({
    getEnv: () => interpreter.currentEnv,
    output: (...values) => console.log(...values),
    services: {
      getStandardErrors: id => standardErrors[String(id)] ?? [],
      // Optional synchronous providers (e.g. caches populated before execute):
      // getUnitById: id => ...,
      // getUnitByName: name => ...,
      // convertUnit: (fromUnitId, toUnitId, value) => ...,
    },
  }),
});
interpreter.execute('return FIND_STD_ERROR(1, 15);');
```

`getEnv` is required for implicit row selection and the `_UNIT_` cache. It reads
`currentEnv`, so CURRENT_ROWS declared inside interpreted functions also works.
Pass `variables: { CURRENT_ROWS: [0, 0] }` to the interpreter context in TS,
or `variables: {'CURRENT_ROWS': [0, 0]}` in Dart. Indices are zero-based;
`GET_CURRENT_ROW_INDEX(1)` reads the second level. The legacy `CURRENT_ROW`
name remains supported when `CURRENT_ROWS` is absent.

Legacy metadata at the beginning of a script or formula is ignored:

```js
#CURRENT_ROW = 0,1
return ROW([10, 20], null, 1) // Uses variables.CURRENT_ROWS[1]
```

The directive does not supply row indices. Pass `CURRENT_ROWS` (or legacy
`CURRENT_ROW`) through `variables`. Without row variables, implicit row selection
throws an error. Keep legacy metadata on its own line before JavaScript statements.
The following signatures use `?` for an optional argument.

| Group | Functions |
| --- | --- |
| Results | `SUCCESS(value = null, message?)`, `ERROR(message = "", data = null)` |
| Arrays | `FIRST(array)`, `LAST(array, returnIndex = false)`, `COUNT(array)`, `SORTING(array, direction = "asc")`, `FIND_INDEX(array, value, last = false)` |
| Mapping | `MAP(data, mapKey, filters?, exclude = false)`, `SUM(data, key)` or `SUM(...values)` |
| Row | `ROW(array, manualIndex = null, level = 0)`, `GET_CURRENT_ROW_INDEX(level = 0)` |
| Lookup | `MATCH(value, array, matchType = 1)`, `INDEX(matrix, rowIndex, columnIndex)` |
| Conversion | `NUMBER(value)`, `NUM(value)`, `STR(value)`, `IS_INFINITY(value)`, `EMPTY(value)`, `ISNULL(value)`, `FORMAT_EXPO(value, fractionDigits?)`, `DECIMAL_PLACES(value)` |
| Aggregation | `MIN(...values)`, `MAX(...values)`, `AVERAGE(...values)`, `STDEV(...values)`, `SUMSQ(...values)` |
| Math | `ABS(value)`, `SQRT(value)`, `POWER(base, exponent)`, `EXP(value)`, `LOG(value, base = 10)` (also `"e"`) |
| Rounding | `FIXED(value, digits = 2)`, `ROUND(value, digits = 0)`, `ROUNDUP(value, digits = 0)`, `ROUNDDOWN(value, digits = 0)`, `INT(value)`, `SIG(value, figures = 2)` |
| Statistical / numerical | `TINV(probability, degreesOfFreedom)`, `TREND(knownY, knownX, newX)`, `MMULT(a, b)`, `MINVERSE(matrix)`, `GOAL_SEEK(fn, target, tolerance = 1e-6, maxIterations = 100)` |
| Random | `RAND()`, `RANDBETWEEN(min, max)` |
| Reference | `FIND_REF_SETTING(setting, verticalValue, horizontalValue?)` |
| Standard | `FIND_STD_ERROR(id, calibrationPoint?, compareField = "uncertainty", returnIndex = false)`, `GET_STD_BY_INDEX(id, index, column?)`, `GET_STD_BY_VALUE(id, value)` |
| Unit | `UNIT(id)`, `UNIT_ID(name)`, `UNIT_CONVERT(fromId, toId, value)` |

## Behavior

- All lookup/row indexes are **zero based**. `FIRST([])` and `LAST([])` return null.
  FIND_INDEX returns null for no match; its third argument chooses the last match.
- MAP filters by the collection's original keys/indexes, not by mapped values.
  A falsy mapKey (e.g. null) maps the values themselves. Object property values
  that can be converted to numbers are converted, as in the reference.
- MATCH's original `_MATCH` helper was not included in the supplied snippet.
  This implementation defines mode 0 as exact (first match), 1 as last <= lookup
  in ascending input, and -1 as last >= lookup in descending input. No match
  returns -1. Inputs for approximate matching must be sorted in that order.
- ROW uses CURRENT_ROWS[level] (falling back to CURRENT_ROW) unless manualIndex
  is supplied and is neither null nor false. An explicit index needs no row context.
- SUM(data, key) sums that field from an array/object of records. Existing
  variadic/nested-array SUM, MIN, MAX, AVERAGE, STDEV and SUMSQ remain available.
  AVERAGE([]) and STDEV([]) return 0; a singleton STDEV returns NaN.
- SORTING mutates the input array, like the supplied reference. MINVERSE and
  standard lookup sorting do not mutate their input.
- ROUNDUP rounds away from zero; ROUNDDOWN truncates toward zero; INT floors.
  TINV is the two-tailed Student t inverse, using jStat's studentt.inv(1-p/2, df).
  It requires 0 < p <= 1 and positive integer df. The jStat API is documented at
  https://jstat.github.io/distributions.html.
- GOAL_SEEK brackets in both directions then bisects. It requires a continuous
  finite-valued callback with a discoverable sign-changing bracket. It reports
  missing brackets or failure to converge instead of returning a fake result.
- FIND_REF_SETTING expects `{ rows, columns, datas }` and chooses the larger
  adjacent row value between calibration points, matching the supplied reference.
- FIND_STD_ERROR sorts standard rows by value, returns null outside the range,
  and chooses the adjacent row with the larger comparison field between points.
  Exact points return the exact row or its index. The original snippet's
  reference-before-declaration bug on `useIndex` is corrected.
- GET_STD_BY_INDEX(id, null/false, column) returns the whole column.
- UNIT first reads `_UNIT_[id]`; its fallback provider accepts either an existing
  `{ID, SYMBOL, NAME}` record or CRM `{unit_id, unit_short_name_en, unit_name_en}`.
  UNIT_ID's provider returns a record with ID or unit_id.
- Standard/Unit services must be supplied by the caller; no database credentials,
  HTTP endpoint, or auth token are hardcoded. **Load API/database data before
  execute and use synchronous providers**. Promise providers are rejected because
  this interpreter does not await host function results. Unconfigured services
  produce explicit errors; configured lookups can return null or empty records.

## Validation

```sh
npx tsx --test testing.ts
```

The entry point also includes `tests/functions.test.ts`: registry coverage for
all reference names, interpreted callbacks, numerical checks, row context,
preloaded Standard/Unit providers and error cases.

`testing.ts` provides an independently named execution test for each of the 51
reference functions and `print`, plus edge cases and validation tests. All run
through a fresh InterpreterService. Standard/Unit tests use in-memory providers.
Run the function cases with `npx tsx --test testing.ts`.
