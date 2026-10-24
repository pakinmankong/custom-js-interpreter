import 'dart:convert';
import 'dart:io';
import 'lib/custom_js_interpreter.dart';

void main() {
  final data =
      jsonDecode(
            File.fromUri(
              Platform.script.resolve('example_data.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final code = File.fromUri(
    Platform.script.resolve('example_code.js'),
  ).readAsStringSync();
  late final InterpreterService interpreter;
  interpreter = InterpreterService(
    InterpreterContext(resolver: false,
      variables: data,
      functions: createFunctions(
        getEnv: () => interpreter.currentEnv,
        output: (values) => stdout.writeln(values.map(jsString).join(' ')),
      ),
    ),
  );
  try {
    final result = interpreter.execute(code);
    stdout.writeln('result: ${jsString(result)}');
  } catch (error) {
    stderr.writeln(
      formatInterpreterError(
        createInterpreterError(error, 'script', interpreter.lineOffset, code),
      ),
    );
    exitCode = 1;
  }
}
