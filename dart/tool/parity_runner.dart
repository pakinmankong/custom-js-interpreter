import 'dart:convert';
import 'dart:io';
import '../lib/custom_js_interpreter.dart';
import '../lib/runtime.dart' show JsCallable;

dynamic encode(dynamic value) {
  if (value is JsUndefined) return {r'$undefined': true};
  if (value is num && !value.isFinite)
    return {
      r'$number': value.isNaN
          ? 'NaN'
          : value.isNegative
          ? '-Infinity'
          : 'Infinity',
    };
  if (value is BigInt) return {r'$bigint': value.toString()};
  if (value is JsCallable || value is Function) return {r'$function': true};
  if (value is List) return value.map(encode).toList();
  if (value is Map) return value.map((k, v) => MapEntry(k, encode(v)));
  return value;
}

Future<void> main() async {
  final cases = jsonDecode(await stdin.transform(utf8.decoder).join()) as List;
  final results = <dynamic>[];
  for (final fixture in cases) {
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
    functions.addAll({
      'HOST_ADD': NativeFunction((args, t) => args[0] + args[1]),
      'HOST_APPLY': NativeFunction(
        (args, t) => fixture['async'] == true
            ? interpreter.callFunctionAsync(args[0], [args[1]], undefined)
            : interpreter.callFunction(args[0], [args[1]], undefined),
      ),
      'HOST_IDENTITY': NativeFunction((args, t) => args[0]),
      'DOUBLE': (dynamic n) async => n * 2,
      'COMPARE': (dynamic a, dynamic b) async => a - b,
      'FAIL': () async {
        throw JsError('service failed');
      },
    });
    if (fixture['group'] == 'async') {
      functions['FIND_STD_ERROR'] = (dynamic id, dynamic value) async => {
        'uncertainty': value * 2,
      };
    }
    interpreter = InterpreterService(
      InterpreterContext(
        resolver: true,
        astBundle: fixture.containsKey('astCache')
            ? CompiledAstBundle.fromJson(fixture['astCache'])
            : null,
        requireCachedAst: fixture.containsKey('astCache'),
        variables: {
          'CURRENT_ROW': [1, 0],
          '_UNIT_': {
            '1': {'ID': 1, 'SYMBOL': 'm', 'NAME': 'metre'},
          },
          ...?fixture['variables'] as Map<String, dynamic>?,
        },
        functions: functions,
      ),
    );
    try {
      final value = fixture['async'] == true
          ? await interpreter.executeAsync(fixture['code'])
          : interpreter.execute(fixture['code']);
      results.add({
        'status': 'ok',
        'value': encode(value),
        'calls': encode(calls),
      });
    } catch (error) {
      results.add({
        'status': 'error',
        'error': error.toString(),
        'calls': encode(calls),
      });
    }
  }
  stdout.writeln(jsonEncode(results));
}
