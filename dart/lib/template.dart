import 'errors.dart';

/// Scan a template and its nested expressions without treating inner backticks
/// or braces inside quoted strings/comments as the end of the outer template.
({int end, List<String> parts, List<String> expressions}) scanTemplate(
  String source,
  int start,
) {
  var i = start + 1;
  final parts = <String>[], expressions = <String>[];
  final raw = StringBuffer();
  while (i < source.length) {
    if (source[i] == r'\') {
      raw.write(source[i++]);
      if (i < source.length) raw.write(source[i++]);
      continue;
    }
    if (source[i] == '`') {
      parts.add(cookTemplate(raw.toString()));
      return (end: i + 1, parts: parts, expressions: expressions);
    }
    if (source.startsWith(r'${', i)) {
      parts.add(cookTemplate(raw.toString()));
      raw.clear();
      final begin = i + 2;
      i = _expressionEnd(source, begin);
      expressions.add(source.substring(begin, i));
      i++;
      continue;
    }
    raw.write(source[i++]);
  }
  throw JsError('Unterminated template literal', position: start);
}

int _expressionEnd(String source, int start) {
  var i = start, depth = 1;
  while (i < source.length) {
    final c = source[i];
    if (c == '"' || c == "'") {
      final quote = c;
      i++;
      while (i < source.length && source[i] != quote) {
        if (source[i] == r'\') i++;
        i++;
      }
      i++;
      continue;
    }
    if (c == '`') {
      i = scanTemplate(source, i).end;
      continue;
    }
    if (source.startsWith('//', i)) {
      while (i < source.length && !'\n\r\u2028\u2029'.contains(source[i])) {
        i++;
      }
      continue;
    }
    if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      if (end < 0) throw JsError('Unterminated comment');
      i = end + 2;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  throw JsError('Unterminated template interpolation', position: start);
}

String cookTemplate(String raw) {
  raw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final result = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (raw[i] != r'\') {
      result.write(raw[i]);
      continue;
    }
    i++;
    if (i >= raw.length) throw JsError('Invalid template escape');
    final c = raw[i];
    const escapes = {
      'n': '\n',
      'r': '\r',
      't': '\t',
      'b': '\b',
      'f': '\f',
      'v': '\v',
      '0': '\x00',
    };
    if (c == '\n') continue;
    if (c == '\r') {
      if (i + 1 < raw.length && raw[i + 1] == '\n') i++;
      continue;
    }
    if (c == 'u' || c == 'x') {
      final count = c == 'u' ? 4 : 2;
      if (i + count >= raw.length) throw JsError('Invalid template escape');
      final code = int.tryParse(raw.substring(i + 1, i + 1 + count), radix: 16);
      if (code == null) throw JsError('Invalid template escape');
      result.writeCharCode(code);
      i += count;
    } else {
      result.write(escapes[c] ?? c);
    }
  }
  return result.toString();
}
