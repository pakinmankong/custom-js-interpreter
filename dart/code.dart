import 'dart:io';

import 'lib/custom_js_interpreter.dart';

const _usage = '''Usage:
  dart dart/code.dart                         Parse and run dart/code.js
  dart dart/code.dart --code path/code.js     Parse and run another JS file
  dart dart/code.dart --ast path/cache.json   Run the main entry from AST JSON
  dart dart/code.dart --ast path/cache.json --code path/code.js
                                              Prefer cached AST; parse on a miss
  dart dart/code.dart --ast path/cache.json --strict
                                              Require AST for main and formulas
''';

void main(List<String> args) {
  if (args.contains('--help')) {
    stdout.write(_usage);
    return;
  }
  InterpreterService? interpreter;
  var code = '';
  var sourceName = 'code.js';
  try {
    String? astPath, codePath;
    var strict = false;
    for (var i = 0; i < args.length; i++) {
      final option = args[i];
      if (option == '--strict') {
        strict = true;
      } else if (option == '--ast' || option == '--code') {
        if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
          throw ArgumentError('$option requires a file path');
        }
        final path = args[++i];
        if (option == '--ast') {
          astPath = path;
        } else {
          codePath = path;
        }
      } else {
        throw ArgumentError('Unknown option: $option');
      }
    }
    if (strict && astPath == null) {
      throw ArgumentError('--strict requires --ast');
    }

    CompiledAstBundle? bundle;
    if (astPath != null) {
      sourceName = astPath;
      bundle = CompiledAstBundle.decode(File(astPath).readAsStringSync());
    }
    if (codePath != null || bundle == null) {
      // Default JS file is relative to this runner, explicit paths use the CWD.
      final file = codePath == null
          ? File.fromUri(Platform.script.resolve('code.js'))
          : File(codePath);
      sourceName = file.path;
      code = file.readAsStringSync();
    } else {
      if (bundle.codes.length != 1) {
        throw ArgumentError(
          'Use --code to select a main entry when the bundle does not contain exactly one',
        );
      }
      code = bundle.codes.single;
    }

    interpreter = InterpreterService(
      InterpreterContext(
        astBundle: bundle,
        requireCachedAst: strict,
        // เพิ่มข้อมูลที่ต้องการส่งให้ JavaScript ตรงนี้
        variables: {
          'input': 10,
          '_SOURCE_': {
            'GROUP1': {
              'ddd': {'ddd': 111},
            },
          },
        },
        functions: createFunctions(
          getEnv: () => interpreter!.currentEnv,
          output: (values) => stdout.writeln(values.map(jsString).join(' ')),
        ),
      ),
    );
    // execute() prefers an imported AST, and parses only if missing and allowed.
    final result = bundle != null && codePath == null
        ? interpreter.executeCached()
        : interpreter.execute(code);
    stdout.writeln('result: ${jsString(result)}');
  } catch (error) {
    if (error is ArgumentError) {
      stderr.writeln(error.message);
      stderr.write(_usage);
    } else {
      stderr.writeln(
        formatInterpreterError(
          createInterpreterError(
            error,
            sourceName,
            interpreter?.lineOffset ?? 0,
            code,
          ),
        ),
      );
    }
    exitCode = 1;
  }
}
