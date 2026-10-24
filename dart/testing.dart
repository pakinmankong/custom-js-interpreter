import 'dart:convert';
import 'dart:io';
import 'function_testing.dart';
import 'ast_cache_testing.dart';
import 'lib/custom_js_interpreter.dart';
import 'lib/builtins.dart';

bool equal(dynamic a, dynamic b) {
  if (a is num && b is num && a.isNaN && b.isNaN) return true;
  if (a is JsUndefined || b is JsUndefined)
    return a is JsUndefined && b is JsUndefined;
  if (a is List && b is List)
    return a.length == b.length &&
        List.generate(a.length, (i) => equal(a[i], b[i])).every((v) => v);
  if (a is Map && b is Map)
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && equal(a[k], b[k]));
  return a == b;
}

dynamic decode(dynamic value) {
  if (value is Map && value.length == 1 && value[r'$undefined'] == true)
    return undefined;
  if (value is List) return value.map(decode).toList();
  if (value is Map) return value.map((k, v) => MapEntry(k, decode(v)));
  return value;
}

void main() {
  var passed = 0, failed = 0;
  void test(String name, void Function() body) {
    try {
      body();
      passed++;
      stdout.writeln('PASS $name');
    } catch (error, stack) {
      failed++;
      stderr.writeln('FAIL $name\n$error\n$stack');
    }
  }

  void expect(dynamic actual, dynamic expected) {
    if (!equal(actual, expected))
      throw StateError('Expected $expected, received $actual');
  }

  final fixtures =
      jsonDecode(
            File.fromUri(
              Platform.script.resolve('test_cases.json'),
            ).readAsStringSync(),
          )
          as List;
  for (final fixture in fixtures) {
    test(fixture['name'], () {
      final interpreter = InterpreterService();
      if (fixture.containsKey('error')) {
        Object? caught;
        try {
          interpreter.execute(fixture['code']);
        } catch (error) {
          caught = error;
        }
        if (caught == null ||
            !RegExp(fixture['error']).hasMatch(caught.toString()))
          throw StateError(
            'Expected error ${fixture['error']}, received $caught',
          );
      } else {
        expect(
          interpreter.execute(fixture['code']),
          decode(fixture['expected']),
        );
      }
    });
  }
  test('resolver defaults to false and requires explicit opt-in', () {
    final variables = {'DATA': {'value': 'return 5', 'cell': {'formula': 'return 6'}, 'unit': 'uuid-text'}};
    for (final context in [InterpreterContext(variables: variables), InterpreterContext(variables: variables, resolver: false)]) {
      final interpreter = InterpreterService(context);
      expect(interpreter.execute('return [DATA.value,DATA.cell.formula,DATA.unit];'), ['return 5', 'return 6', 'uuid-text']);
      expect(interpreter.dataResolver.cache.length, 0);
    }
    final interpreter = InterpreterService(InterpreterContext(variables: variables, resolver: true));
    expect(interpreter.execute('return [DATA.value,DATA.cell,DATA.unit];'), [5, 6, 'uuid-text']);
  });
  test('print arguments, expressions, loop and nested function', () {
    final calls = <List<dynamic>>[];
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, 
        functions: {
          'print': NativeFunction((args, receiver) {
            calls.add(List.of(args));
            return undefined;
          }),
        },
      ),
    );
    final result = interpreter.execute('''
      function show(value) { print("value:", value); }
      for (var i=0; i<3; i++) { show(i); }
      return print("hello", 2+3, true, null, [1,2]);
    ''');
    expect(calls, [
      ['value:', 0],
      ['value:', 1],
      ['value:', 2],
      [
        'hello',
        5,
        true,
        null,
        [1, 2],
      ],
    ]);
    expect(result, undefined);
  });
  test('data formulas, named arrays, columns, children and RECORDS alias', () {
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, 
        variables: {
          '_RECORDS_': {
            'group': {
              'columns': [
                {'name': 'A', 'formula': 'return B + 1'},
                {'name': 'B', 'formula': 'return 10'},
              ],
              'children': {'C': 'return 5'},
            },
          },
        },
      ),
    );
    expect(
      interpreter.execute('return RECORDS.group.A + RECORDS.group.C;'),
      16,
    );
    expect(interpreter.dataResolver.cache['_RECORDS_.group.A'], 11);
    interpreter.dataResolver.clearCache();
    expect(interpreter.dataResolver.cache.length, 0);
  });
  test('circular dependency and evaluating stack cleanup', () {
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, 
        variables: {
          'DATA': {'A': 'return B', 'B': 'return A'},
        },
      ),
    );
    Object? caught;
    try {
      interpreter.execute('return DATA.A;');
    } catch (error) {
      caught = error;
    }
    if (caught == null || !caught.toString().contains('Circular dependency:'))
      throw StateError('Expected cycle error');
    expect(interpreter.dataResolver.evaluating, []);
  });
  test('while, do while, spread, default/rest arguments and template', () {
    expect(
      InterpreterService().execute(r'''
      function sum(a=2, ...rest) { return rest.reduce((n,v)=>n+v,a); }
      var i=0; while(i<2) { i++; }
      do { i++; } while(i<3);
      return [sum(), sum(...[1,2,3]), `i=${i}`];
    '''),
      [2, 6, 'i=3'],
    );
  });
  test('error location and formatting', () {
    final interpreter = InterpreterService();
    try {
      interpreter.execute('return missing;');
      throw StateError('Expected error');
    } on JsError catch (e) {
      final error = createInterpreterError(e, 'script', 1, 'return missing;');
      expect(error.line, 1);
      if (!formatInterpreterError(
        error,
      ).contains('Undefined variable: missing'))
        throw StateError('Missing error message');
    }
  });
  test('external error formatting preserves metadata lines and newline types', () {
    for (final newline in ['\n', '\r\n', '\r', '\u2028', '\u2029']) {
      final code = '#CURRENT_ROW=0,1${newline}sdfds';
      final interpreter = InterpreterService();
      Object? caught;
      try {
        interpreter.execute(code);
      } catch (error) {
        caught = error;
      }
      if (caught == null) throw StateError('Expected undefined variable error');
      final error = createInterpreterError(caught, 'script', interpreter.lineOffset, code);
      expect(error.line, 2);
      expect(error.column, 0);
      if (!formatInterpreterError(error).contains('> 2 | sdfds')) {
        throw StateError('Incorrect source line in formatted error');
      }
      if (!identical(createInterpreterError(error, 'script', 1), error)) {
        throw StateError('InterpreterError should not have its offset subtracted twice');
      }
    }
  });
  test('nested formula error formatting retains original source', () {
    const formula = 'return 123invalid';
    final interpreter = InterpreterService(InterpreterContext(resolver: true, 
      variables: {'DATA': {'field': {'formula': formula}}},
    ));
    Object? caught;
    try {
      interpreter.execute('return DATA.field;');
    } catch (error) {
      caught = error;
    }
    if (caught == null) throw StateError('Expected formula error');
    final error = createInterpreterError(caught, 'script', 1, 'return DATA.field;');
    expect(error.source, 'DATA.field');
    expect(error.sourceCode, formula);
    expect(error.line, 1);
    if (!formatInterpreterError(error).contains('> 1 | $formula')) {
      throw StateError('Expected formula source in error');
    }
    expect(interpreter.dataResolver.evaluating.length, 0);
  });
  test('data strings remain literal while legacy and explicit formulas execute', () {
    const id = 'bd4d74c0-275e-45b5-928b-68fa4f30a505';
    final interpreter = InterpreterService(InterpreterContext(resolver: true, variables: {
      '_UUC_DETAIL_': {'unit': id, 'resolution': '0.1', 'make': 'Magnetic Flowmeter', 'empty': '', 'numericText': '123invalid'},
      'DATA': {'A': 'return 5;', 'B': '// comment\n#CURRENT_ROW=0\nreturn A+1;', 'C': {'formula': 'return 7;'}, 'bad': {'formula': '123invalid'}},
    }));
    expect(interpreter.execute('return [_UUC_DETAIL_["unit"],_UUC_DETAIL_.resolution,_UUC_DETAIL_.make,_UUC_DETAIL_.empty,_UUC_DETAIL_.numericText,DATA.A,DATA.B,DATA.C];'), [id, '0.1', 'Magnetic Flowmeter', '', '123invalid', 5, 6, 7]);
    Object? caught;
    try { interpreter.execute('return DATA.bad;'); } catch (error) { caught = error; }
    if (caught is! InterpreterError || caught.source != 'DATA.bad') {
      throw StateError('Expected explicit invalid formula to throw');
    }
  });
  test('example math functions ported from index.ts', () {
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, functions: createExampleFunctions()),
    );
    expect(
      interpreter.execute('''
      return [NUMBER("10"), POWER(2,3), EXP(0), SUM([1,2],3),
        AVERAGE(1,2,3), STDEV(1,2,3), SUMSQ(1,2,3),
        TREND([2,4,6],[1,2,3],4), MIN([3,1]), MAX(1,3),
        ABS(-5), SQRT(16), LOG(100), FIXED(3.14559,2), ROUND(3.54159,4),
        DECIMAL_PLACES(3.14), FIND_INDEX(["1",2],1), SIG(0.000123456)];
    '''),
      [
        10,
        8,
        1,
        6,
        2,
        1,
        14,
        8,
        1,
        3,
        5,
        4,
        2,
        '3.15',
        3.5416,
        2,
        0,
        '0.00013',
      ],
    );
    final random = interpreter.execute('return RAND();') as num;
    if (random < 0 || random >= 1) throw StateError('RAND out of range');
  });
  test('BigInt, regex literal, optional property and nullish coalescing', () {
    expect(
      InterpreterService().execute(r'''
      var missing = null;
      return [1n + 2n, /^hello$/i.test("HELLO"), missing?.value ?? 10];
    '''),
      [BigInt.from(3), true, 10],
    );
  });
  test('unsupported syntax reports an error', () {
    Object? caught;
    try {
      InterpreterService().execute('return new Date();');
    } catch (error) {
      caught = error;
    }
    if (caught == null || !caught.toString().contains('Unsupported syntax'))
      throw StateError('Expected unsupported syntax error');
  });
  runFunctionTests(test, expect);
  runAstCacheTests(test, expect);
  stdout.writeln('$passed passed, $failed failed');
  if (failed > 0) exitCode = 1;
}
