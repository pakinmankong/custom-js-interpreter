import 'errors.dart';

class Env {
  final Map<String, dynamic> vars = {};
  final Set<String> constants = {};
  final Env? parent;
  Env([this.parent]);

  bool hasOwn(String name) => vars.containsKey(name);
  bool has(String name) => hasOwn(name) || (parent?.has(name) ?? false);

  dynamic define(String name, dynamic value, [bool constant = false]) {
    if (constants.contains(name)) {
      throw JsError('Assignment to constant variable: $name');
    }
    vars[name] = value;
    if (constant) constants.add(name);
    return value;
  }

  dynamic get(String name) {
    if (hasOwn(name)) return vars[name];
    if (parent != null) return parent!.get(name);
    throw JsError('Undefined identifier: $name');
  }

  dynamic set(String name, dynamic value) {
    if (hasOwn(name)) {
      if (constants.contains(name)) {
        throw JsError('Assignment to constant variable: $name');
      }
      return vars[name] = value;
    }
    if (parent?.has(name) ?? false) return parent!.set(name, value);
    throw JsError('Undefined variable: $name');
  }
}
