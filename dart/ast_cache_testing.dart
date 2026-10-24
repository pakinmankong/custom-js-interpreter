import 'dart:convert';
import 'dart:io';
import 'lib/custom_js_interpreter.dart';

void runAstCacheTests(
  void Function(String, void Function()) test,
  void Function(dynamic, dynamic) expect,
) {
  final text = File.fromUri(
    Platform.script.resolve('ast_cache_example.json'),
  ).readAsStringSync();
  test(
    'TS AST JSON executes directly with fresh inputs, without source parsing',
    () {
      final bundle = CompiledAstBundle.decode(text);
      expect(bundle.length, 1);
      final interpreter = InterpreterService(
        InterpreterContext(resolver: true, 
          astBundle: bundle,
          requireCachedAst: true,
          variables: {'input': 2},
          functions: createFunctions(),
        ),
      );
      expect(interpreter.executeCached(), [
        6,
        BigInt.from(4),
        double.infinity,
        'value=3',
        2,
      ]);
      interpreter.globalEnv.set('input', 9);
      expect(interpreter.executeCached(), [
        6,
        BigInt.from(4),
        double.infinity,
        'value=3',
        9,
      ]);
    },
  );
  test('compiled AST strict mode refuses a missing source', () {
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, 
        astBundle: CompiledAstBundle.decode(text),
        requireCachedAst: true,
      ),
    );
    Object? caught;
    try {
      interpreter.execute('return 99;');
    } catch (error) {
      caught = error;
    }
    if (caught == null || !caught.toString().contains('AST cache miss'))
      throw StateError('Expected AST cache miss');
  });
  test('compiled bundle validates version parser and duplicate entries', () {
    final json = jsonDecode(text) as Map<String, dynamic>;
    for (final invalid in [
      {...json, 'version': 2},
      {...json, 'parser': 'unknown'},
      {
        ...json,
        'entries': [...(json['entries'] as List), ...(json['entries'] as List)],
      },
      {
        ...json,
        'entries': [
          {
            'source': 'x',
            'ast': {'type': 'ClassDeclaration'},
          },
        ],
      },
    ]) {
      var rejected = false;
      try {
        CompiledAstBundle.fromJson(invalid);
      } on FormatException {
        rejected = true;
      }
      if (!rejected) throw StateError('Expected malformed bundle rejection');
    }
  });
  test(
    'compiled bundle rejects mutation and missing/ambiguous main entries',
    () {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final bundle = CompiledAstBundle.fromJson(json);
      final source = (json['entries'] as List).single['source'] as String;
      var rejected = false;
      try {
        bundle.lookup(source)!['body'] = [];
      } on UnsupportedError {
        rejected = true;
      }
      if (!rejected) throw StateError('Cached AST must be read-only');
      final empty = CompiledAstBundle.fromJson({...json, 'entries': []});
      Object? caught;
      try {
        InterpreterService(
          InterpreterContext(resolver: true, astBundle: empty),
        ).executeCached();
      } catch (error) {
        caught = error;
      }
      if (caught == null || !caught.toString().contains('exactly one main'))
        throw StateError('Expected missing main rejection');
    },
  );
  test('Dart parses JS independently without an AST bundle', () {
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, functions: createFunctions()),
    );
    expect(
      interpreter.execute(
        'const double = v => v * 2; return [1,2,3].map(double);',
      ),
      [2, 4, 6],
    );
  });
  test('AST main can call a formula parsed locally when not in the bundle', () {
    final json = jsonDecode(text) as Map<String, dynamic>;
    const code = 'return DATA.A;';
    final bundle = CompiledAstBundle.fromJson({
      ...json,
      'entries': [
        {
          'source': 'function __USER_MAIN__() {\n$code\n}',
          'ast': {
            'type': 'File',
            'program': {
              'type': 'Program',
              'body': [
                {
                  'type': 'FunctionDeclaration',
                  'id': {'type': 'Identifier', 'name': '__USER_MAIN__'},
                  'params': [],
                  'body': {
                    'type': 'BlockStatement',
                    'body': [
                      {
                        'type': 'ReturnStatement',
                        'argument': {
                          'type': 'MemberExpression',
                          'object': {'type': 'Identifier', 'name': 'DATA'},
                          'property': {'type': 'Identifier', 'name': 'A'},
                          'computed': false,
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      ],
    });
    final interpreter = InterpreterService(
      InterpreterContext(resolver: true, 
        astBundle: bundle,
        variables: {
          'DATA': {'A': 'return 2 + 3;'},
        },
      ),
    );
    expect(interpreter.executeCached(), 5);
    expect(interpreter.execute('return 10 + 1;'), 11);
    final strict = InterpreterService(
      InterpreterContext(resolver: true, 
        astBundle: bundle,
        requireCachedAst: true,
        variables: {
          'DATA': {'A': 'return 2 + 3;'},
        },
      ),
    );
    Object? caught;
    try {
      strict.executeCached();
    } catch (error) {
      caught = error;
    }
    if (caught == null || !caught.toString().contains('AST cache miss')) {
      throw StateError('Strict mode must reject a formula not in the bundle');
    }
  });
  test(
    'automatic semicolon insertion rejects adjacent same-line statements',
    () {
      for (final code in [
        'var a=1 var b=2',
        'var text=`a\nb` var n=2',
        'var text="a\nb"',
      ]) {
        var rejected = false;
        try {
          InterpreterService().execute(code);
        } on JsError {
          rejected = true;
        }
        if (!rejected)
          throw StateError('Expected invalid source to be rejected: $code');
      }
    },
  );
}
