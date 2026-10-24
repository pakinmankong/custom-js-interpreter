import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'lib/custom_js_interpreter.dart';

class _Setup {
  final InterpreterService interpreter;
  final List<List<dynamic>> calls;
  _Setup(this.interpreter, this.calls);
}

_Setup _setup([
  Map<String, dynamic>? variables,
  bool resolver = false,
  CompiledAstBundle? bundle,
  bool strict = false,
]) {
  final calls = <List<dynamic>>[];
  late final InterpreterService interpreter;
  Future<dynamic> later(dynamic value) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return value;
  }

  interpreter = InterpreterService(
    InterpreterContext(
      variables: variables,
      resolver: resolver,
      astBundle: bundle,
      requireCachedAst: strict,
      functions: {
        ...createFunctions(getEnv: () => interpreter.currentEnv),
        'DOUBLE': (dynamic n) async => await later(n * 2),
        'COMPARE': (dynamic a, dynamic b) async => await later(a - b),
        'FIND_STD_ERROR': (dynamic id, dynamic value) async =>
            await later({'uncertainty': value * 2}),
        'FAIL': () async {
          await later(0);
          throw JsError('service failed');
        },
        'HOST_APPLY': NativeFunction(
          (args, receiver) async => await interpreter.callFunctionAsync(
            args[0],
            [args[1]],
            undefined,
          ),
        ),
        'print': NativeFunction((args, receiver) async {
          await later(0);
          calls.add(List.of(args));
          return undefined;
        }),
      },
    ),
  );
  return _Setup(interpreter, calls);
}

dynamic _decode(dynamic value) {
  if (value is Map && value[r'$undefined'] == true) return undefined;
  if (value is List) return value.map(_decode).toList();
  return value;
}

Future<void> runAsyncTests(
  Future<void> Function(String, Future<void> Function()) test,
  void Function(dynamic, dynamic) expect,
) async {
  final fixtures =
      jsonDecode(
            File.fromUri(
              Platform.script.resolve('async_cases.json'),
            ).readAsStringSync(),
          )
          as List;
  for (final fixture in fixtures) {
    await test('async: ${fixture['name']}', () async {
      final setup = _setup();
      final interpreter = setup.interpreter;
      if (fixture.containsKey('error')) {
        Object? caught;
        try {
          await interpreter.executeAsync(fixture['code']);
        } catch (error) {
          caught = error;
        }
        if (caught == null || !caught.toString().contains(fixture['error'])) {
          throw StateError('Expected ${fixture['error']}, got $caught');
        }
        expect(
          createInterpreterError(caught, 'script', 1, fixture['code']).line,
          fixture['line'],
        );
      } else {
        expect(
          await interpreter.executeAsync(fixture['code']),
          _decode(fixture['expected']),
        );
        expect(setup.calls, fixture['calls'] ?? []);
      }
      if (!identical(interpreter.currentEnv, interpreter.globalEnv))
        throw StateError('Environment leaked');
    });
  }
  await test(
    'async resolver awaits dependencies and retains failed formula source',
    () async {
      final interpreter = _setup({
        'DATA': {
          'A': 'return DOUBLE(B);',
          'B': 'return DOUBLE(2);',
          'bad': {'formula': '\nFAIL();'},
        },
      }, true).interpreter;
      expect(await interpreter.executeAsync('return DATA.A;'), 8);
      expect(await interpreter.executeAsync('return DATA.A;'), 8);
      Object? caught;
      try {
        await interpreter.executeAsync('return DATA.bad;');
      } catch (error) {
        caught = error;
      }
      if (caught is! InterpreterError ||
          caught.source != 'DATA.bad' ||
          caught.line != 2) {
        throw StateError('Expected DATA.bad line 2, got $caught');
      }
      expect(interpreter.dataResolver.evaluating.length, 0);
    },
  );
  await test(
    'overlap is rejected and failed async execution releases interpreter',
    () async {
      final interpreter = _setup().interpreter;
      final first = interpreter.executeAsync('return DOUBLE(2);');
      Object? caught;
      try {
        await interpreter.executeAsync('return 99;');
      } catch (error) {
        caught = error;
      }
      if (caught == null || !caught.toString().contains('already running'))
        throw StateError('Expected busy error');
      caught = null;
      try {
        interpreter.execute('return 99;');
      } catch (error) {
        caught = error;
      }
      if (caught == null) throw StateError('Expected synchronous busy error');
      expect(await first, 4);
      try {
        await interpreter.executeAsync('FAIL();');
      } catch (_) {}
      expect(interpreter.execute('return 7;'), 7);
      expect(await interpreter.executeAsync('return DOUBLE(3);'), 6);
    },
  );
  await test(
    'executeCachedAsync awaits host functions in a strict TS AST bundle',
    () async {
      final bundle = CompiledAstBundle.decode(
        File.fromUri(
          Platform.script.resolve('ast_cache_example.json'),
        ).readAsStringSync(),
      );
      final interpreter = InterpreterService(
        InterpreterContext(
          astBundle: bundle,
          requireCachedAst: true,
          variables: {'input': 7},
          functions: {
            'SUM': (dynamic values) async {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              return (values as List).fold<num>(0, (sum, value) => sum + value);
            },
          },
        ),
      );
      expect(await interpreter.executeCachedAsync(), [
        6,
        BigInt.from(4),
        double.infinity,
        'value=3',
        7,
      ]);
      Object? caught;
      try {
        await interpreter.executeCachedAsync('return 99;');
      } catch (error) {
        caught = error;
      }
      if (caught == null || !caught.toString().contains('AST cache miss'))
        throw StateError('Expected strict cache miss');
    },
  );
}
