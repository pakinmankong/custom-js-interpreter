import 'interpreter_service.dart';
import 'env.dart';
import 'errors.dart';

class DataResolver {
  final InterpreterService interpreter;
  final Map<String, dynamic> variables;
  final Map<String, dynamic> cache = {};
  final List<String> evaluating = [];
  DataResolver(this.interpreter, this.variables);
  void clearCache() => cache.clear();
  dynamic resolve(String rootName, List<String> path, Env env) {
    final key = [rootName, ...path].join('.');
    if (cache.containsKey(key)) return cache[key];
    if (evaluating.contains(key)) {
      final cycle = [
        ...evaluating.skip(evaluating.indexOf(key)),
        key,
      ].join(' -> ');
      throw JsError('Circular dependency: $cycle');
    }
    if (!variables.containsKey(rootName))
      throw JsError('Undefined data source: $rootName');
    final node = find(variables[rootName], path);
    if (identical(node, undefined)) throw JsError('Undefined reference: $key');
    if (node is String && _isLegacyFormula(node)) {
      return evaluateFormula(key, node, rootName, path, env);
    }
    if (node is Map && node['formula'] is String)
      return evaluateFormula(key, node['formula'], rootName, path, env);
    cache[key] = node;
    return node;
  }

  bool _isLegacyFormula(String value) => RegExp(
    r'^(?:\s|//[^\r\n\u2028\u2029]*(?:[\r\n\u2028\u2029]|$)|/\*[\s\S]*?\*/|#[Cc][Uu][Rr][Rr][Ee][Nn][Tt]_[Rr][Oo][Ww][^\r\n\u2028\u2029]*(?:[\r\n\u2028\u2029]|$))*(?:return|var|let|const|function|if|for|while|do|switch|try|throw)\b',
  ).hasMatch(value);

  dynamic resolveLocal(
    String name,
    String rootName,
    List<String> path,
    Env env,
  ) {
    final parentPath = path.isEmpty
        ? <String>[]
        : path.sublist(0, path.length - 1);
    final parent = find(variables[rootName], parentPath);
    if (parent is Map) {
      if (parent.containsKey(name))
        return resolve(rootName, [...parentPath, name], env);
      final columns = parent['columns'];
      if (columns is Map && columns.containsKey(name))
        return resolve(rootName, [...parentPath, 'columns', name], env);
      final children = parent['children'];
      if (children is Map && children.containsKey(name))
        return resolve(rootName, [...parentPath, 'children', name], env);
      if (columns is List) {
        final index = columns.indexWhere(
          (item) => item is Map && item['name'] == name,
        );
        if (index != -1)
          return resolve(rootName, [...parentPath, 'columns', '$index'], env);
      }
    }
    if (parent is List) {
      final index = parent.indexWhere(
        (item) => item is Map && item['name'] == name,
      );
      if (index != -1) return resolve(rootName, [...parentPath, '$index'], env);
    }
    throw JsError('Undefined variable: $name');
  }

  dynamic evaluateFormula(
    String key,
    String formula,
    String rootName,
    List<String> path,
    Env env,
  ) {
    evaluating.add(key);
    try {
      final value = interpreter.evaluateFormula(formula, rootName, path, env);
      cache[key] = value;
      return value;
    } catch (error) {
      throw createInterpreterError(error, key, 1, formula);
    } finally {
      evaluating.removeLast();
    }
  }

  dynamic find(dynamic current, List<String> path) {
    for (final part in path) {
      if (current == null || identical(current, undefined)) return undefined;
      if (current is List) {
        final index = int.tryParse(part);
        if (index != null && index >= 0 && index < current.length) {
          current = current[index];
          continue;
        }
        final named = current.indexWhere(
          (item) => item is Map && item['name'] == part,
        );
        if (named == -1) return undefined;
        current = current[named];
        continue;
      }
      if (current is! Map) return undefined;
      if (current.containsKey(part)) {
        current = current[part];
        continue;
      }
      final columns = current['columns'];
      if (columns is List) {
        final index = columns.indexWhere(
          (item) => item is Map && item['name'] == part,
        );
        if (index != -1) {
          current = columns[index];
          continue;
        }
      }
      if (columns is Map && columns.containsKey(part)) {
        current = columns[part];
        continue;
      }
      final children = current['children'];
      if (children is Map && children.containsKey(part)) {
        current = children[part];
        continue;
      }
      return undefined;
    }
    return current;
  }
}
