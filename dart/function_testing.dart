import 'dart:convert';
import 'dart:io';
import 'lib/custom_js_interpreter.dart';

dynamic _decode(dynamic value) {
  if (value is Map && value[r'$undefined'] == true) return undefined;
  if (value is Map && value.containsKey(r'$number'))
    return switch (value[r'$number']) {
      'NaN' => double.nan,
      'Infinity' => double.infinity,
      _ => double.negativeInfinity,
    };
  if (value is List) return value.map(_decode).toList();
  if (value is Map) return value.map((k, v) => MapEntry(k, _decode(v)));
  return value;
}

void runFunctionTests(
  void Function(String, void Function()) test,
  void Function(dynamic, dynamic) expect,
) {
  final fixtures =
      jsonDecode(
            File.fromUri(
              Platform.script.resolve('function_test_cases.json'),
            ).readAsStringSync(),
          )
          as List;
  for (final fixture in fixtures) {
    test(
      'function ${fixture['name']}${fixture.containsKey('error') ? ' validation' : ''}',
      () {
        final calls = <List<dynamic>>[];
        late final InterpreterService interpreter;
        final functions = createFunctions(
          getEnv: () => interpreter.currentEnv,
          output: (values) => calls.add(List.of(values)),
          services: FunctionServices(
            getStandardErrors: (id) => id == 1
                ? [
                    {'value': 20, 'uncertainty': 5},
                    {'value': 10, 'uncertainty': 2},
                    {'value': 30, 'uncertainty': 1},
                  ]
                : [],
            getUnitById: (id) => id == 2
                ? {
                    'unit_id': 2,
                    'unit_short_name_en': 'cm',
                    'unit_name_en': 'centimetre',
                  }
                : null,
            getUnitByName: (name) => name == 'metre' ? {'unit_id': 1} : null,
            convertUnit: (from, to, value) =>
                from == 1 && to == 2 ? value * 100 : null,
          ),
        );
        interpreter = InterpreterService(
          InterpreterContext(
            variables: {
              'CURRENT_ROW': [1, 0],
              '_UNIT_': {
                '1': {'ID': 1, 'SYMBOL': 'm', 'NAME': 'metre'},
              },
            },
            functions: functions,
          ),
        );
        if (fixture.containsKey('error')) {
          Object? caught;
          try {
            interpreter.execute(fixture['code']);
          } catch (error) {
            caught = error;
          }
          if (caught == null ||
              !RegExp(fixture['error']).hasMatch(caught.toString()))
            throw StateError('Expected ${fixture['error']}, got $caught');
          return;
        }
        final actual = interpreter.execute(fixture['code']);
        switch (fixture['check']) {
          case 'RAND':
            if (actual is! num || !actual.isFinite || actual < 0 || actual >= 1)
              throw StateError('RAND out of range: $actual');
          case 'RANDBETWEEN':
            if (actual is! num ||
                actual != actual.truncateToDouble() ||
                actual < 2 ||
                actual > 5)
              throw StateError('RANDBETWEEN out of range: $actual');
          case 'TINV':
          case 'GOAL_SEEK':
            if (actual is! num ||
                (actual - fixture['expected']).abs() >= fixture['tolerance'])
              throw StateError('Expected ${fixture['expected']}, got $actual');
          default:
            expect(actual, _decode(fixture['expected']));
        }
        if (fixture['name'] == 'print')
          expect(calls, [
            ['hello', 5],
          ]);
        final names = fixtures
            .where((v) => !v.containsKey('error'))
            .map((v) => v['name'])
            .toSet();
        for (final name in functions.keys) {
          if (!names.contains(name))
            throw StateError('Missing function case: $name');
        }
      },
    );
  }
  test('GOAL_SEEK block callback, closure and return signal', () {
    final interpreter = InterpreterService(
      InterpreterContext(functions: createFunctions()),
    );
    final result = interpreter.execute(
      'const factor=2;return GOAL_SEEK(function(x){return x*factor;},10);',
    );
    if ((result - 5).abs() > 1e-6) throw StateError('Expected 5, got $result');
  });
  test('MINVERSE product yields identity without mutating input', () {
    final interpreter = InterpreterService(
      InterpreterContext(functions: createFunctions()),
    );
    final result = interpreter.execute(
      'var a=[[4,7],[2,6]];return [MMULT(a,MINVERSE(a)),a];',
    );
    final identity = result[0] as List;
    for (var r = 0; r < 2; r++) {
      for (var c = 0; c < 2; c++) {
        if ((identity[r][c] - (r == c ? 1 : 0)).abs() > 1e-10)
          throw StateError('Bad inverse');
      }
    }
    expect(result[1], [
      [4, 7],
      [2, 6],
    ]);
  });
  test('services report missing configuration', () {
    final interpreter = InterpreterService(
      InterpreterContext(functions: createFunctions()),
    );
    for (final code in [
      'FIND_STD_ERROR(1)',
      'GET_STD_BY_INDEX(1,0)',
      'GET_STD_BY_VALUE(1,0)',
      'UNIT(1)',
      'UNIT_ID("m")',
      'UNIT_CONVERT(1,2,3)',
    ]) {
      Object? caught;
      try {
        interpreter.execute('return $code;');
      } catch (error) {
        caught = error;
      }
      if (caught == null ||
          !caught.toString().contains('service is not configured'))
        throw StateError('Expected service error, got $caught');
    }
  });
  test('Future service data is rejected', () {
    final interpreter = InterpreterService(
      InterpreterContext(
        functions: createFunctions(
          services: FunctionServices(
            getStandardErrors: (id) => Future.value([]),
          ),
        ),
      ),
    );
    Object? caught;
    try {
      interpreter.execute('return FIND_STD_ERROR(1);');
    } catch (error) {
      caught = error;
    }
    if (caught == null ||
        !caught.toString().contains('Future is not supported'))
      throw StateError('Expected Future error, got $caught');
  });
}
