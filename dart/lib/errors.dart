class JsError implements Exception {
  final String message;
  int? line;
  int? column;
  int? position;
  int? length;
  JsError(this.message, {this.line, this.column, this.position, this.length});
  @override
  String toString() => message;
}

class InterpreterError extends JsError {
  final String source;
  final String? sourceCode;
  InterpreterError(
    String message,
    this.source,
    int line,
    int column,
    int position, [
    this.sourceCode,
    int length = 1,
  ]) : super(
         message,
         line: line,
         column: column,
         position: position,
         length: length < 1 ? 1 : length,
       );
}

InterpreterError createInterpreterError(
  Object error,
  String source, [
  int lineOffset = 0,
  String? sourceCode,
]) {
  if (error is InterpreterError) return error;
  final js = error is JsError ? error : JsError(error.toString());
  final line = (js.line ?? 1) - lineOffset;
  return InterpreterError(
    js.message,
    source,
    line < 1 ? 1 : line,
    js.column ?? 0,
    js.position ?? 0,
    sourceCode,
    js.length ?? 1,
  );
}

String formatInterpreterError(InterpreterError error, [String? sourceCode]) {
  final line = error.line ?? 1;
  return '${error.source} error at line $line\n\n'
      '${error.message}';
}
