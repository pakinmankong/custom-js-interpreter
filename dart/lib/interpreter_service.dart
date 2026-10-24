import 'dart:math' as math;
import 'env.dart';
import 'errors.dart';
import 'data_resolver.dart';
import 'parser.dart';
import 'runtime.dart';
import 'compiled_ast_bundle.dart';
export 'runtime.dart' show undefined, JsUndefined, NativeFunction, jsString;
part 'async_evaluator.dart';

class InterpreterContext {
  final bool resolver;
  final Map<String, dynamic> variables;
  final Map<String, dynamic> functions;
  final String code;
  final CompiledAstBundle? astBundle;
  final bool requireCachedAst;
  InterpreterContext({
    this.resolver = false,
    Map<String, dynamic>? variables,
    Map<String, dynamic>? functions,
    this.code = '',
    this.astBundle,
    this.requireCachedAst = false,
  }) : variables = variables ?? {},
       functions = functions ?? {};
}

class _Signal implements Exception {
  final String kind;
  final dynamic value;
  _Signal(this.kind, [this.value = undefined]);
}

class InterpreterFunction implements JsCallable {
  final Node node;
  final Env closure;
  final InterpreterService interpreter;
  InterpreterFunction(this.node, this.closure, this.interpreter);
  @override
  dynamic invoke(List<dynamic> args, dynamic thisValue) {
    final env = Env(closure);
    if (node['type'] != 'ArrowFunctionExpression')
      env.define('this', thisValue);
    final params = node['params'] as List;
    for (var i = 0; i < params.length; i++) {
      final param = params[i];
      var value = i < args.length ? args[i] : undefined;
      switch (param['type']) {
        case 'Identifier':
          env.define(param['name'], value);
        case 'AssignmentPattern':
          if (identical(value, undefined))
            value = interpreter.evaluate(param['right'], env);
          env.define(param['left']['name'], value);
        case 'RestElement':
          env.define(param['argument']['name'], args.skip(i).toList());
      }
    }
    if (node['body']['type'] == 'BlockStatement')
      interpreter.hoistFunctions(node['body']['body'], env);
    final previous = interpreter.currentEnv;
    interpreter.currentEnv = env;
    try {
      final result = interpreter.evaluate(node['body'], env);
      return node['body']['type'] == 'BlockStatement' ? undefined : result;
    } finally {
      interpreter.currentEnv = previous;
    }
  }
}

class Reference {
  final dynamic Function() get;
  final dynamic Function(dynamic) set;
  Reference(this.get, this.set);
}

class InterpreterService {
  bool _asyncRunning = false;
  late final _AsyncEvaluator _asyncEvaluator = _AsyncEvaluator(this);
  final InterpreterContext context;
  final Env globalEnv = Env();
  late Env currentEnv;
  late final DataResolver dataResolver;
  late final JsRuntime runtime;
  String userCode;
  int lineOffset = 0;
  final Set<String> reservedWords = {
    'var',
    'let',
    'const',
    'function',
    'return',
    'if',
    'else',
    'for',
    'while',
    'do',
    'switch',
    'case',
    'default',
    'break',
    'continue',
    'throw',
    'true',
    'false',
    'null',
    'undefined',
    'this',
    'new',
    'typeof',
    'void',
    'delete',
    'in',
    'instanceof',
  };
  InterpreterService([InterpreterContext? context])
    : this.context = context ?? InterpreterContext(),
      userCode = context?.code ?? '' {
    currentEnv = globalEnv;
    for (final entry in this.context.variables.entries) {
      globalEnv.define(entry.key, entry.value);
    }
    for (final entry in this.context.functions.entries) {
      globalEnv.define(entry.key, entry.value);
    }
    dataResolver = DataResolver(this, this.context.variables);
    runtime = JsRuntime(callFunction);
    registerBuiltins();
  }
  void registerBuiltins() {}
  Node parse(String source) {
    final cached = context.astBundle?.lookup(source);
    if (cached != null) return cached;
    if (context.requireCachedAst)
      throw JsError('AST cache miss: source was not included in the bundle');
    return JsParser(_expandRowDirective(source)).parse();
  }

  String _expandRowDirective(String source) {
    final chars = source.split('');
    final modes = <String>['code'];
    final depths = <int>[0];
    final directive = RegExp(
      r'^#CURRENT_ROW[\t ]*=[\t ]*(?:\d+(?:[\t ]*,[\t ]*\d+)*)?[\t ]*;?[\t ]*(?://[^\r\n\u2028\u2029]*)?(?=[\r\n\u2028\u2029]|$)',
      caseSensitive: false,
    );
    var lineStart = 0;
    void push(String mode, [int depth = 0]) {
      modes.add(mode);
      depths.add(depth);
    }

    void pop() {
      modes.removeLast();
      depths.removeLast();
    }

    for (var i = 0; i < source.length; i++) {
      final c = source[i], next = i + 1 < source.length ? source[i + 1] : '';
      if ('\r\n\u2028\u2029'.contains(c)) lineStart = i + 1;
      final mode = modes.last;
      if (mode == 'line') {
        if ('\r\n\u2028\u2029'.contains(c)) pop();
        continue;
      }
      if (mode == 'block') {
        if (c == '*' && next == '/') {
          pop();
          i++;
        }
        continue;
      }
      if (mode != 'code') {
        if (c == r'\') {
          i++;
          continue;
        }
        if (c == mode) {
          pop();
          continue;
        }
        if (mode == '`' && c == r'$' && next == '{') {
          push('code', 1);
          i++;
        }
        continue;
      }
      if (c == '#' &&
          RegExp(r'^[\t ]*$').hasMatch(source.substring(lineStart, i))) {
        final match = directive.firstMatch(source.substring(i));
        if (match != null) {
          for (var j = i; j < i + match.end; j++) {
            chars[j] = ' ';
          }
          i += match.end - 1;
          continue;
        }
      }
      if (c == '/' && (next == '/' || next == '*')) {
        push(next == '/' ? 'line' : 'block');
        i++;
      } else if (c == '"' || c == "'" || c == '`') {
        push(c);
      } else if (depths.last > 0) {
        if (c == '{') depths[depths.length - 1]++;
        if (c == '}') {
          depths[depths.length - 1]--;
          if (depths.last == 0) pop();
        }
      }
    }
    return chars.join();
  }

  /// Run an imported execute() entry without needing a separate JS source file.
  /// If there are multiple main entries, pass the desired exact code explicitly.
  dynamic executeCached([String? code]) {
    final bundle = context.astBundle;
    if (bundle == null) throw JsError('No compiled AST bundle was provided');
    if (code == null) {
      final codes = bundle.codes;
      if (codes.length != 1)
        throw JsError(
          'Specify code when the AST bundle does not contain exactly one main entry',
        );
      code = codes.single;
    }
    if (bundle.lookup('function __USER_MAIN__() {\n$code\n}') == null)
      throw JsError(
        'AST cache miss: main entry was not included in the bundle',
      );
    return execute(code);
  }

  dynamic execute([String? code]) {
    if (_asyncRunning)
      throw JsError(
        'An asynchronous execution is already running on this interpreter',
      );
    userCode = code ?? userCode;
    lineOffset = 1;
    final ast = parse('function __USER_MAIN__() {\n$userCode\n}');
    final fn = ast['body'][0] as Node;
    hoistFunctions(fn['body']['body'], globalEnv);
    return callFunction(createFunction(fn, globalEnv), [], undefined);
  }

  dynamic evaluateFormula(
    String formula,
    String rootName,
    List<String> path,
    Env env,
  ) {
    final ast = parse('function __FORMULA__() {\n$formula\n}');
    final formulaEnv = Env(env);
    formulaEnv.define('__FORMULA_ROOT__', rootName);
    formulaEnv.define('__FORMULA_PATH__', path);
    return callFunction(
      createFunction(ast['body'][0], formulaEnv),
      [],
      undefined,
    );
  }

  Future<dynamic> executeAsync([String? code]) async {
    if (_asyncRunning)
      throw JsError(
        'An asynchronous execution is already running on this interpreter',
      );
    _asyncRunning = true;
    userCode = code ?? userCode;
    lineOffset = 1;
    try {
      final ast = parse('function __USER_MAIN__() {\n$userCode\n}');
      final node = ast['body'][0] as Node;
      _asyncEvaluator.hoistFunctions(node['body']['body'], globalEnv);
      return await _asyncEvaluator.callFunction(
        _asyncEvaluator.createFunction(node, globalEnv),
        [],
        undefined,
      );
    } finally {
      _asyncRunning = false;
    }
  }

  Future<dynamic> executeCachedAsync([String? code]) async {
    final bundle = context.astBundle;
    if (bundle == null) throw JsError('No compiled AST bundle was provided');
    if (code == null) {
      if (bundle.codes.length != 1)
        throw JsError(
          'Specify code when the AST bundle does not contain exactly one main entry',
        );
      code = bundle.codes.single;
    }
    if (bundle.lookup('function __USER_MAIN__() {\n$code\n}') == null) {
      throw JsError('AST cache miss: source was not included in the bundle');
    }
    return await executeAsync(code);
  }

  Future<dynamic> evaluateFormulaAsync(
    String formula,
    String rootName,
    List<String> path,
    Env env,
  ) async {
    final ast = parse('function __FORMULA__() {\n$formula\n}');
    final formulaEnv = Env(env);
    formulaEnv.define('__FORMULA_ROOT__', rootName);
    formulaEnv.define('__FORMULA_PATH__', path);
    return await _asyncEvaluator.callFunction(
      _asyncEvaluator.createFunction(ast['body'][0], formulaEnv),
      [],
      undefined,
    );
  }

  Future<dynamic> callFunctionAsync(
    dynamic fn,
    List<dynamic> args, [
    dynamic thisValue = undefined,
  ]) => _asyncEvaluator.callFunction(fn, args, thisValue);

  String getDataRootName(String name) => name == 'RECORDS' ? '_RECORDS_' : name;
  ({String root, List<String> path})? getDataReferencePath(Node node, Env env) {
    if (!context.resolver) return null;
    if (node['type'] == 'Identifier') {
      final root = getDataRootName(node['name']);
      return context.variables.containsKey(root)
          ? (root: root, path: <String>[])
          : null;
    }
    if (![
      'MemberExpression',
      'OptionalMemberExpression',
    ].contains(node['type']))
      return null;
    final parent = getDataReferencePath(node['object'], env);
    if (parent == null) return null;
    final property = node['computed'] == true
        ? jsString(evaluate(node['property'], env))
        : node['property']['name'] as String;
    return (root: parent.root, path: [...parent.path, property]);
  }

  void hoistFunctions(List<dynamic> body, Env env) {
    for (final node in body) {
      if (node['type'] == 'FunctionDeclaration')
        env.define(node['id']['name'], createFunction(node, env));
    }
  }

  InterpreterFunction createFunction(Node node, Env closure) =>
      InterpreterFunction(node, closure, this);
  dynamic callFunction(
    dynamic fn,
    List<dynamic> args, [
    dynamic thisValue = undefined,
  ]) {
    if (fn is InterpreterFunction) {
      try {
        return fn.invoke(args, thisValue);
      } on _Signal catch (signal) {
        if (signal.kind == 'return') return signal.value;
        rethrow;
      }
    }
    if (fn is JsCallable) return fn.invoke(args, thisValue);
    if (fn is Function) {
      final nativeArgs = args
          .map(
            (arg) => arg is InterpreterFunction
                ? NativeFunction(
                    (callbackArgs, receiver) =>
                        callFunction(arg, callbackArgs, receiver),
                  )
                : arg,
          )
          .toList();
      return Function.apply(fn, nativeArgs);
    }
    throw JsError('Value is not a function');
  }

  Reference getReferenceValue(Node node, Env env) {
    if (node['type'] == 'Identifier')
      return Reference(
        () => env.get(node['name']),
        (value) => env.set(node['name'], value),
      );
    if ([
      'MemberExpression',
      'OptionalMemberExpression',
    ].contains(node['type'])) {
      final object = evaluate(node['object'], env);
      if (isNullish(object))
        throw JsError('Cannot access property of null or undefined');
      final property = node['computed'] == true
          ? evaluate(node['property'], env)
          : node['property']['name'];
      return Reference(
        () => runtime.property(object, property),
        (value) => runtime.setProperty(object, property, value),
      );
    }
    throw JsError('Invalid assignment target');
  }

  dynamic setReferenceValue(Node node, dynamic value, Env env) =>
      getReferenceValue(node, env).set(value);
  void assignLoopVariable(Node left, dynamic value, Env env) {
    if (left['type'] == 'VariableDeclaration') {
      final declaration = left['declarations'][0];
      final name = declaration['id']['name'] as String;
      if (left['kind'] == 'var' && env.has(name)) {
        env.set(name, value);
      } else {
        env.define(name, value, left['kind'] == 'const');
      }
    } else {
      setReferenceValue(left, value, env);
    }
  }

  dynamic evaluate(Node? node, Env env) {
    if (node == null) return undefined;
    try {
      return _evaluate(node, env);
    } on JsError catch (error) {
      error.line ??= node['line'];
      error.column ??= node['column'];
      error.position ??= node['start'];
      rethrow;
    }
  }

  dynamic _evaluate(Node node, Env env) {
    switch (node['type']) {
      case 'Program':
      case 'BlockStatement':
        dynamic result = undefined;
        for (final statement in node['body']) {
          result = evaluate(statement, env);
        }
        return result;
      case 'EmptyStatement':
        return undefined;
      case 'ExpressionStatement':
        return evaluate(node['expression'], env);
      case 'VariableDeclaration':
        dynamic result = undefined;
        for (final d in node['declarations']) {
          if (d['id']['type'] != 'Identifier')
            throw JsError('Variable declaration must use an identifier');
          result = env.define(
            d['id']['name'],
            evaluate(d['init'], env),
            node['kind'] == 'const',
          );
        }
        return result;
      case 'FunctionDeclaration':
        final fn = createFunction(node, env);
        env.define(node['id']['name'], fn);
        return fn;
      case 'FunctionExpression':
      case 'ArrowFunctionExpression':
        return createFunction(node, env);
      case 'CallExpression':
        return evaluateCallExpression(node, env);
      case 'ReturnStatement':
        throw _Signal('return', evaluate(node['argument'], env));
      case 'BreakStatement':
        throw _Signal('break');
      case 'ContinueStatement':
        throw _Signal('continue');
      case 'Identifier':
        final name = node['name'] as String;
        if (env.has(name)) return env.get(name);
        final root = env.has('__FORMULA_ROOT__')
            ? env.get('__FORMULA_ROOT__')
            : null;
        final path = env.has('__FORMULA_PATH__')
            ? env.get('__FORMULA_PATH__')
            : null;
        if (context.resolver && root is String && path is List<String>)
          return dataResolver.resolveLocal(name, root, path, env);
        throw JsError('Undefined variable: $name');
      case 'NumericLiteral':
        return (node['value'] as num).toDouble();
      case 'StringLiteral':
      case 'BooleanLiteral':
      case 'BigIntLiteral':
        return node['value'];
      case 'NullLiteral':
        return null;
      case 'RegExpLiteral':
        return JsRegExp(node['pattern'], node['flags']);
      case 'ArrayExpression':
        final array = <dynamic>[];
        for (final element in node['elements']) {
          if (element != null && element['type'] == 'SpreadElement') {
            array.addAll(runtime.iterable(evaluate(element['argument'], env)));
          } else {
            array.add(evaluate(element, env));
          }
        }
        return array;
      case 'ObjectExpression':
        final object = <String, dynamic>{};
        for (final property in node['properties']) {
          if (property['type'] == 'SpreadElement') {
            final spread = evaluate(property['argument'], env);
            for (final key in runtime.keys(spread)) {
              object[key] = runtime.property(spread, key);
            }
          } else {
            final key = property['computed'] == true
                ? evaluate(property['key'], env)
                : property['key']['name'] ?? property['key']['value'];
            object[jsString(key)] = evaluate(property['value'], env);
          }
        }
        return object;
      case 'MemberExpression':
      case 'OptionalMemberExpression':
        final reference = getDataReferencePath(node, env);
        if (reference != null)
          return dataResolver.resolve(reference.root, reference.path, env);
        final object = evaluate(node['object'], env);
        if (isNullish(object) && node['optional'] == true) return undefined;
        final property = node['computed'] == true
            ? evaluate(node['property'], env)
            : node['property']['name'];
        return runtime.property(object, property);
      case 'AssignmentExpression':
        final right = evaluate(node['right'], env);
        if (node['operator'] == '=')
          return setReferenceValue(node['left'], right, env);
        final reference = getReferenceValue(node['left'], env);
        final op = node['operator'] as String;
        return reference.set(
          binary(op.substring(0, op.length - 1), reference.get(), right),
        );
      case 'UpdateExpression':
        final reference = getReferenceValue(node['argument'], env);
        final oldValue = reference.get();
        final newValue = node['operator'] == '++'
            ? binary('+', oldValue, 1)
            : binary('-', oldValue, 1);
        reference.set(newValue);
        return node['prefix'] == true ? newValue : oldValue;
      case 'BinaryExpression':
        return evaluateBinaryExpression(node, env);
      case 'LogicalExpression':
        return evaluateLogicalExpression(node, env);
      case 'UnaryExpression':
        return evaluateUnaryExpression(node, env);
      case 'ConditionalExpression':
        return evaluate(
          truthy(evaluate(node['test'], env))
              ? node['consequent']
              : node['alternate'],
          env,
        );
      case 'IfStatement':
        return evaluate(
          truthy(evaluate(node['test'], env))
              ? node['consequent']
              : node['alternate'],
          env,
        );
      case 'ForStatement':
        evaluate(node['init'], env);
        while (node['test'] == null || truthy(evaluate(node['test'], env))) {
          try {
            evaluate(node['body'], env);
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
          evaluate(node['update'], env);
        }
        return undefined;
      case 'ForOfStatement':
      case 'ForInStatement':
        final right = evaluate(node['right'], env);
        final values = node['type'] == 'ForOfStatement'
            ? runtime.iterable(right)
            : runtime.keys(right);
        for (final value in values) {
          final left = node['left'] as Node;
          final iterationEnv =
              left['type'] == 'VariableDeclaration' && left['kind'] != 'var'
              ? Env(env)
              : env;
          assignLoopVariable(left, value, iterationEnv);
          try {
            evaluate(node['body'], iterationEnv);
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
        }
        return undefined;
      case 'WhileStatement':
      case 'DoWhileStatement':
        var first = node['type'] == 'DoWhileStatement';
        while (first || truthy(evaluate(node['test'], env))) {
          first = false;
          try {
            evaluate(node['body'], env);
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
        }
        return undefined;
      case 'SequenceExpression':
        dynamic result = undefined;
        for (final expression in node['expressions']) {
          result = evaluate(expression, env);
        }
        return result;
      case 'ThisExpression':
        return env.get('this');
      case 'TemplateLiteral':
        if (node.containsKey('quasis')) {
          // Babel JSON already contains parsed expression nodes. Do not reparse
          // interpolations, including nested templates and object expressions.
          final result = StringBuffer();
          final quasis = node['quasis'] as List,
              expressions = node['expressions'] as List;
          for (var i = 0; i < quasis.length; i++) {
            result.write(quasis[i]['value']['cooked']);
            if (i < expressions.length)
              result.write(jsString(evaluate(expressions[i], env)));
          }
          return result.toString();
        }
        final template = node['value'] as Map;
        final parts = template['parts'] as List,
            expressions = template['expressions'] as List;
        final result = StringBuffer(parts[0]);
        for (var i = 0; i < expressions.length; i++) {
          final parser = JsParser(expressions[i]);
          final expression = parser.expression();
          if (parser.token.kind != 'eof')
            throw JsError('Unexpected token in template interpolation');
          result.write(jsString(evaluate(expression, env)));
          result.write(parts[i + 1]);
        }
        return result.toString();
      case 'SpreadElement':
        return evaluate(node['argument'], env);
      case 'ParenthesizedExpression':
        return evaluate(node['expression'], env);
      default:
        throw JsError('Unknown node type: ${node['type']}');
    }
  }

  dynamic evaluateCallExpression(Node node, Env env) {
    dynamic thisValue = undefined;
    dynamic fn;
    var functionName = '<anonymous>';
    final callee = node['callee'] as Node;
    if ([
      'MemberExpression',
      'OptionalMemberExpression',
    ].contains(callee['type'])) {
      thisValue = evaluate(callee['object'], env);
      if (isNullish(thisValue)) {
        if (callee['optional'] == true) return undefined;
        throw JsError('Cannot call method of null or undefined');
      }
      final property = callee['computed'] == true
          ? evaluate(callee['property'], env)
          : callee['property']['name'];
      functionName = jsString(property);
      fn = runtime.property(thisValue, property);
    } else {
      if (callee['type'] == 'Identifier') {
        functionName = callee['name'];
        if (!env.has(functionName))
          throw JsError('Undefined function: $functionName()');
      }
      fn = evaluate(callee, env);
    }
    if (isNullish(fn)) throw JsError('Undefined function: $functionName()');
    if (fn is! JsCallable && fn is! Function)
      throw JsError('$functionName is not a function');
    final args = <dynamic>[];
    for (final argument in node['arguments']) {
      if (argument['type'] == 'SpreadElement') {
        args.addAll(runtime.iterable(evaluate(argument['argument'], env)));
      } else {
        args.add(evaluate(argument, env));
      }
    }
    return callFunction(fn, args, thisValue);
  }

  dynamic evaluateBinaryExpression(Node node, Env env) => binary(
    node['operator'],
    evaluate(node['left'], env),
    evaluate(node['right'], env),
  );
  dynamic binary(String op, dynamic left, dynamic right) {
    if (['+', '-', '*', '/', '%', '**'].contains(op) &&
        (left is BigInt) != (right is BigInt) &&
        !(op == '+' &&
            (left is String ||
                right is String ||
                left is List ||
                right is List ||
                left is Map ||
                right is Map))) {
      throw JsError(
        'Cannot mix BigInt and other types, use explicit conversions',
      );
    }
    switch (op) {
      case '+':
        if (left is String ||
            right is String ||
            left is List ||
            right is List ||
            left is Map ||
            right is Map)
          return jsString(left) + jsString(right);
        if (left is BigInt && right is BigInt) return left + right;
        return jsNumber(left) + jsNumber(right);
      case '-':
        return left is BigInt && right is BigInt
            ? left - right
            : jsNumber(left) - jsNumber(right);
      case '*':
        return left is BigInt && right is BigInt
            ? left * right
            : jsNumber(left) * jsNumber(right);
      case '/':
        return left is BigInt && right is BigInt
            ? left ~/ right
            : jsNumber(left) / jsNumber(right);
      case '%':
        if (left is BigInt && right is BigInt) return left.remainder(right);
        return jsNumber(left).remainder(jsNumber(right));
      case '**':
        return left is BigInt && right is BigInt
            ? left.pow(right.toInt())
            : math.pow(jsNumber(left), jsNumber(right));
      case '==':
        return looseEqual(left, right);
      case '!=':
        return !looseEqual(left, right);
      case '===':
        return strictEqual(left, right);
      case '!==':
        return !strictEqual(left, right);
      case '<':
        return left is String && right is String
            ? left.compareTo(right) < 0
            : jsNumber(left) < jsNumber(right);
      case '<=':
        return left is String && right is String
            ? left.compareTo(right) <= 0
            : jsNumber(left) <= jsNumber(right);
      case '>':
        return left is String && right is String
            ? left.compareTo(right) > 0
            : jsNumber(left) > jsNumber(right);
      case '>=':
        return left is String && right is String
            ? left.compareTo(right) >= 0
            : jsNumber(left) >= jsNumber(right);
      case 'in':
        return runtime.hasProperty(right, left);
      case 'instanceof':
        throw JsError(
          'instanceof requires a JavaScript constructor; Dart types are not JavaScript constructors',
        );
      default:
        throw JsError('Unsupported binary operator: $op');
    }
  }

  dynamic evaluateLogicalExpression(Node node, Env env) {
    final left = evaluate(node['left'], env);
    return switch (node['operator']) {
      '&&' => truthy(left) ? evaluate(node['right'], env) : left,
      '||' => truthy(left) ? left : evaluate(node['right'], env),
      '??' => isNullish(left) ? evaluate(node['right'], env) : left,
      _ => throw JsError('Unsupported logical operator: ${node['operator']}'),
    };
  }

  dynamic evaluateUnaryExpression(Node node, Env env) {
    if (node['operator'] == 'typeof' &&
        node['argument']['type'] == 'Identifier' &&
        !env.has(node['argument']['name'])) {
      return 'undefined';
    }
    final argument = evaluate(node['argument'], env);
    switch (node['operator']) {
      case '+':
        if (argument is BigInt)
          throw JsError('Cannot convert a BigInt value to a number');
        return jsNumber(argument);
      case '-':
        return argument is BigInt ? -argument : -jsNumber(argument);
      case '!':
        return !truthy(argument);
      case '~':
        return argument is BigInt ? ~argument : ~toInt32(argument);
      case 'typeof':
        return jsTypeof(argument);
      case 'void':
        return undefined;
      case 'delete':
        final target = node['argument'] as Node;
        if ([
          'MemberExpression',
          'OptionalMemberExpression',
        ].contains(target['type'])) {
          return runtime.deleteProperty(
            evaluate(target['object'], env),
            target['computed'] == true
                ? evaluate(target['property'], env)
                : target['property']['name'],
          );
        }
        return true;
      default:
        throw JsError('Unsupported unary operator: ${node['operator']}');
    }
  }
}
