import 'dart:convert';
import 'parser.dart' show Node;

/// A read-only snapshot exported by the TypeScript AST cache. This does not
/// parse JavaScript or store environments, results or executable host functions.
class CompiledAstBundle {
  final Map<String, Node> _entries;
  CompiledAstBundle._(this._entries);
  int get length => _entries.length;
  Node? lookup(String source) => _entries[source];

  factory CompiledAstBundle.decode(String json) =>
      CompiledAstBundle.fromJson(jsonDecode(json));

  factory CompiledAstBundle.fromJson(dynamic json) {
    if (json is! Map ||
        json['format'] != 'custom-js-interpreter.ast-cache' ||
        json['version'] != 1 ||
        json['parser'] != 'babel-7-script-v1' ||
        json['entries'] is! List) {
      throw FormatException('Unsupported AST cache JSON format/version/parser');
    }
    final entries = <String, Node>{};
    for (final entry in json['entries']) {
      if (entry is! Map || entry['source'] is! String || entry['ast'] is! Map)
        throw FormatException('Invalid AST cache entry');
      final source = entry['source'] as String;
      if (entries.containsKey(source))
        throw FormatException('Duplicate AST cache source');
      final file = _decodeValue(entry['ast']);
      if (file is! Map ||
          file['type'] != 'File' ||
          file['program'] is! Map ||
          file['program']['type'] != 'Program' ||
          file['program']['body'] is! List) {
        throw FormatException(
          'AST cache entry must contain a Babel File/Program',
        );
      }
      entries[source] = file['program'] as Node;
    }
    return CompiledAstBundle._(Map.unmodifiable(entries));
  }

  /// Source code of wrapped execute() entries, in exported LRU order.
  List<String> get codes {
    const prefix = 'function __USER_MAIN__() {\n';
    const suffix = '\n}';
    return List.unmodifiable(
      _entries.keys
          .where((s) => s.startsWith(prefix) && s.endsWith(suffix))
          .map((s) => s.substring(prefix.length, s.length - suffix.length)),
    );
  }
}

const _nodeTypes = {
  'File',
  'Program',
  'BlockStatement',
  'EmptyStatement',
  'ExpressionStatement',
  'VariableDeclaration',
  'VariableDeclarator',
  'FunctionDeclaration',
  'FunctionExpression',
  'ArrowFunctionExpression',
  'CallExpression',
  'ReturnStatement',
  'Identifier',
  'NumericLiteral',
  'StringLiteral',
  'BooleanLiteral',
  'NullLiteral',
  'BigIntLiteral',
  'RegExpLiteral',
  'ArrayExpression',
  'ObjectExpression',
  'ObjectProperty',
  'MemberExpression',
  'OptionalMemberExpression',
  'AssignmentExpression',
  'UpdateExpression',
  'BinaryExpression',
  'LogicalExpression',
  'UnaryExpression',
  'ConditionalExpression',
  'IfStatement',
  'ForStatement',
  'ForOfStatement',
  'ForInStatement',
  'WhileStatement',
  'DoWhileStatement',
  'BreakStatement',
  'ContinueStatement',
  'SequenceExpression',
  'ThisExpression',
  'TemplateLiteral',
  'TemplateElement',
  'SpreadElement',
  'ParenthesizedExpression',
  'AssignmentPattern',
  'RestElement',
  'Directive',
  'DirectiveLiteral',
};
dynamic _decodeValue(dynamic value) {
  if (value is List) return List<dynamic>.unmodifiable(value.map(_decodeValue));
  if (value is! Map) return value;
  if (value.length == 1 && value.containsKey(r'$number')) {
    return switch (value[r'$number']) {
      'Infinity' => double.infinity,
      '-Infinity' => double.negativeInfinity,
      'NaN' => double.nan,
      _ => throw FormatException('Invalid AST number encoding'),
    };
  }
  final node = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) throw FormatException('AST keys must be strings');
    node[entry.key] = _decodeValue(entry.value);
  }
  final type = node['type'];
  if (type != null && !_nodeTypes.contains(type))
    throw FormatException('Unsupported cached AST node: $type');
  if (type == 'BigIntLiteral') {
    if (node['value'] is! String)
      throw FormatException('Invalid BigInt literal');
    node['value'] = BigInt.parse(node['value']);
  }
  if (type == 'RegExpLiteral' &&
      (node['flags'] as String).split('').any((f) => !'gimsuy'.contains(f))) {
    throw FormatException('Unsupported cached RegExp flags: ${node['flags']}');
  }
  final loc = node['loc'];
  if (loc is Map && loc['start'] is Map) {
    node['line'] = loc['start']['line'];
    node['column'] = loc['start']['column'];
  }
  return Map<String, dynamic>.unmodifiable(node);
}
