part of 'interpreter_service.dart';

/// Sequential Future-aware evaluation; synchronous execution keeps its own path.
class _AsyncEvaluator {
  final InterpreterService service;
  _AsyncEvaluator(this.service);
  InterpreterContext get context => service.context;
  Env get currentEnv => service.currentEnv;
  set currentEnv(Env env) => service.currentEnv = env;
  DataResolver get dataResolver => service.dataResolver;
  JsRuntime get runtime => service.runtime;
  String getDataRootName(String name) => service.getDataRootName(name);
  dynamic binary(String op, dynamic left, dynamic right) =>
      service.binary(op, left, right);
  Future<({String root, List<String> path})?> getDataReferencePath(
    Node node,
    Env env,
  ) async {
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
    final parent = (await getDataReferencePath(node['object'], env));
    if (parent == null) return null;
    final property = node['computed'] == true
        ? jsString((await evaluate(node['property'], env)))
        : node['property']['name'] as String;
    return (root: parent.root, path: [...parent.path, property]);
  }

  void hoistFunctions(List<dynamic> body, Env env) {
    for (final node in body) {
      if (node['type'] == 'FunctionDeclaration')
        env.define(node['id']['name'], createFunction(node, env));
    }
  }

  _AsyncInterpreterFunction createFunction(Node node, Env closure) =>
      _AsyncInterpreterFunction(node, closure, this);

  Future<dynamic> callFunction(
    dynamic fn,
    List<dynamic> args, [
    dynamic thisValue = undefined,
  ]) async {
    if (fn is _AsyncInterpreterFunction || fn is InterpreterFunction) {
      try {
        return await fn.invoke(args, thisValue);
      } on _Signal catch (signal) {
        if (signal.kind == 'return') return signal.value;
        rethrow;
      }
    }
    if (fn is NativeFunction && fn.asyncBody != null)
      return await fn.asyncBody!(args, thisValue);
    if (fn is JsCallable) return await fn.invoke(args, thisValue);
    if (fn is Function) {
      final nativeArgs = args
          .map(
            (arg) =>
                arg is _AsyncInterpreterFunction || arg is InterpreterFunction
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

  Future<Reference> getReferenceValue(Node node, Env env) async {
    if (node['type'] == 'Identifier')
      return Reference(
        () => env.get(node['name']),
        (value) => env.set(node['name'], value),
      );
    if ([
      'MemberExpression',
      'OptionalMemberExpression',
    ].contains(node['type'])) {
      final object = (await evaluate(node['object'], env));
      if (isNullish(object))
        throw JsError('Cannot access property of null or undefined');
      final property = node['computed'] == true
          ? (await evaluate(node['property'], env))
          : node['property']['name'];
      return Reference(
        () => runtime.property(object, property),
        (value) => runtime.setProperty(object, property, value),
      );
    }
    throw JsError('Invalid assignment target');
  }

  Future<dynamic> setReferenceValue(Node node, dynamic value, Env env) async =>
      (await getReferenceValue(node, env)).set(value);

  Future<dynamic> assignLoopVariable(Node left, dynamic value, Env env) async {
    if (left['type'] == 'VariableDeclaration') {
      final declaration = left['declarations'][0];
      final name = declaration['id']['name'] as String;
      if (left['kind'] == 'var' && env.has(name)) {
        env.set(name, value);
      } else {
        env.define(name, value, left['kind'] == 'const');
      }
    } else {
      (await setReferenceValue(left, value, env));
    }
  }

  Future<dynamic> evaluate(Node? node, Env env) async {
    if (node == null) return undefined;
    try {
      return (await _evaluate(node, env));
    } on JsError catch (error) {
      error.line ??= node['line'];
      error.column ??= node['column'];
      error.position ??= node['start'];
      error.length ??= _nodeLength(node);
      rethrow;
    } on _Signal {
      rethrow;
    } catch (error) {
      throw JsError(
        error.toString(),
        line: node['line'],
        column: node['column'],
        position: node['start'],
        length: _nodeLength(node),
      );
    }
  }

  Future<dynamic> _evaluate(Node node, Env env) async {
    switch (node['type']) {
      case 'Program':
      case 'BlockStatement':
        dynamic result = undefined;
        for (final statement in node['body']) {
          result = (await evaluate(statement, env));
        }
        return result;
      case 'EmptyStatement':
        return undefined;
      case 'ExpressionStatement':
        return (await evaluate(node['expression'], env));
      case 'VariableDeclaration':
        dynamic result = undefined;
        for (final d in node['declarations']) {
          if (d['id']['type'] != 'Identifier')
            throw JsError('Variable declaration must use an identifier');
          result = env.define(
            d['id']['name'],
            (await evaluate(d['init'], env)),
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
        throw _Signal('return', (await evaluate(node['argument'], env)));
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
          return dataResolver.resolveLocalAsync(name, root, path, env);
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
            array.addAll(
              runtime.iterable((await evaluate(element['argument'], env))),
            );
          } else {
            array.add((await evaluate(element, env)));
          }
        }
        return array;
      case 'ObjectExpression':
        final object = <String, dynamic>{};
        for (final property in node['properties']) {
          if (property['type'] == 'SpreadElement') {
            final spread = (await evaluate(property['argument'], env));
            for (final key in runtime.keys(spread)) {
              object[key] = runtime.property(spread, key);
            }
          } else {
            final key = property['computed'] == true
                ? (await evaluate(property['key'], env))
                : property['key']['name'] ?? property['key']['value'];
            object[jsString(key)] = (await evaluate(property['value'], env));
          }
        }
        return object;
      case 'MemberExpression':
      case 'OptionalMemberExpression':
        final reference = (await getDataReferencePath(node, env));
        if (reference != null)
          return dataResolver.resolveAsync(reference.root, reference.path, env);
        final object = (await evaluate(node['object'], env));
        if (isNullish(object) && node['optional'] == true) return undefined;
        final property = node['computed'] == true
            ? (await evaluate(node['property'], env))
            : node['property']['name'];
        return runtime.property(object, property);
      case 'AssignmentExpression':
        final right = (await evaluate(node['right'], env));
        if (node['operator'] == '=')
          return (await setReferenceValue(node['left'], right, env));
        final reference = (await getReferenceValue(node['left'], env));
        final op = node['operator'] as String;
        return reference.set(
          binary(op.substring(0, op.length - 1), reference.get(), right),
        );
      case 'UpdateExpression':
        final reference = (await getReferenceValue(node['argument'], env));
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
        return (await evaluate(
          truthy((await evaluate(node['test'], env)))
              ? node['consequent']
              : node['alternate'],
          env,
        ));
      case 'IfStatement':
        return (await evaluate(
          truthy((await evaluate(node['test'], env)))
              ? node['consequent']
              : node['alternate'],
          env,
        ));
      case 'ForStatement':
        (await evaluate(node['init'], env));
        while (node['test'] == null ||
            truthy((await evaluate(node['test'], env)))) {
          try {
            (await evaluate(node['body'], env));
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
          (await evaluate(node['update'], env));
        }
        return undefined;
      case 'ForOfStatement':
      case 'ForInStatement':
        final right = (await evaluate(node['right'], env));
        final values = node['type'] == 'ForOfStatement'
            ? runtime.iterable(right)
            : runtime.keys(right);
        for (final value in values) {
          final left = node['left'] as Node;
          final iterationEnv =
              left['type'] == 'VariableDeclaration' && left['kind'] != 'var'
              ? Env(env)
              : env;
          (await assignLoopVariable(left, value, iterationEnv));
          try {
            (await evaluate(node['body'], iterationEnv));
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
        }
        return undefined;
      case 'WhileStatement':
      case 'DoWhileStatement':
        var first = node['type'] == 'DoWhileStatement';
        while (first || truthy((await evaluate(node['test'], env)))) {
          first = false;
          try {
            (await evaluate(node['body'], env));
          } on _Signal catch (signal) {
            if (signal.kind == 'break') break;
            if (signal.kind != 'continue') rethrow;
          }
        }
        return undefined;
      case 'SequenceExpression':
        dynamic result = undefined;
        for (final expression in node['expressions']) {
          result = (await evaluate(expression, env));
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
              result.write(jsString((await evaluate(expressions[i], env))));
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
          result.write(jsString((await evaluate(expression, env))));
          result.write(parts[i + 1]);
        }
        return result.toString();
      case 'SpreadElement':
        return (await evaluate(node['argument'], env));
      case 'ParenthesizedExpression':
        return (await evaluate(node['expression'], env));
      default:
        throw JsError('Unknown node type: ${node['type']}');
    }
  }

  Future<dynamic> evaluateCallExpression(Node node, Env env) async {
    dynamic thisValue = undefined;
    dynamic fn;
    var functionName = '<anonymous>';
    final callee = node['callee'] as Node;
    if ([
      'MemberExpression',
      'OptionalMemberExpression',
    ].contains(callee['type'])) {
      thisValue = (await evaluate(callee['object'], env));
      if (isNullish(thisValue)) {
        if (callee['optional'] == true) return undefined;
        throw JsError('Cannot call method of null or undefined');
      }
      final property = callee['computed'] == true
          ? (await evaluate(callee['property'], env))
          : callee['property']['name'];
      functionName = jsString(property);
      fn = runtime.property(thisValue, property);
    } else {
      if (callee['type'] == 'Identifier') {
        functionName = callee['name'];
        if (!env.has(functionName))
          throw JsError('Undefined function: $functionName()');
      }
      fn = (await evaluate(callee, env));
    }
    if (isNullish(fn)) throw JsError('Undefined function: $functionName()');
    if (fn is! JsCallable && fn is! Function)
      throw JsError('$functionName is not a function');
    final args = <dynamic>[];
    for (final argument in node['arguments']) {
      if (argument['type'] == 'SpreadElement') {
        args.addAll(
          runtime.iterable((await evaluate(argument['argument'], env))),
        );
      } else {
        args.add((await evaluate(argument, env)));
      }
    }
    if (thisValue is List &&
        fn is NativeFunction &&
        fn.arrayMethod == functionName &&
        const {
          'map',
          'filter',
          'forEach',
          'some',
          'every',
          'find',
          'findIndex',
          'reduce',
          'reduceRight',
          'sort',
        }.contains(functionName) &&
        (functionName != 'sort' ||
            (args.isNotEmpty && !identical(args[0], undefined)))) {
      return await _arrayCallback(thisValue, functionName, args);
    }
    if (thisValue is String &&
        functionName == 'replace' &&
        args.length > 1 &&
        (args[1] is JsCallable || args[1] is Function)) {
      return await runtime.replaceAsync(
        thisValue,
        args[0],
        args[1],
        callFunction,
      );
    }
    return await callFunction(fn, args, thisValue);
  }

  Future<dynamic> _arrayCallback(
    List list,
    String name,
    List<dynamic> args,
  ) async {
    if (args.isEmpty || (args[0] is! JsCallable && args[0] is! Function)) {
      throw JsError('Callback is not a function');
    }
    final callback = args[0];
    if (name == 'sort') {
      final values = list
          .where((v) => !identical(v, undefined) && !identical(v, arrayHole))
          .toList();
      final undefinedCount = list.where((v) => identical(v, undefined)).length;
      final length = list.length;
      for (var i = 1; i < values.length; i++) {
        final value = values[i];
        var j = i;
        while (j > 0 &&
            jsNumber(
                  await callFunction(callback, [
                    values[j - 1],
                    value,
                  ], undefined),
                ) >
                0) {
          values[j] = values[j - 1];
          j--;
        }
        values[j] = value;
      }
      list.setAll(0, [
        ...values,
        ...List.filled(undefinedCount, undefined),
        ...List.filled(length - values.length - undefinedCount, arrayHole),
      ]);
      return list;
    }
    final length = list.length;
    final result = name == 'map'
        ? List<dynamic>.filled(length, arrayHole)
        : <dynamic>[];
    final reduce = name == 'reduce' || name == 'reduceRight';
    final step = name == 'reduceRight' ? -1 : 1;
    var index = step > 0 ? 0 : length - 1;
    bool inRange() => index >= 0 && index < length;
    dynamic accumulator = args.length > 1 ? args[1] : undefined;
    bool present() => index < list.length && !identical(list[index], arrayHole);
    if (reduce && args.length < 2) {
      while (inRange() && !present()) {
        index += step;
      }
      if (!inRange())
        throw JsError('Reduce of empty array with no initial value');
      accumulator = list[index];
      index += step;
    }
    for (; inRange(); index += step) {
      if (!present() && name != 'find' && name != 'findIndex') continue;
      final value = index < list.length ? arrayValue(list[index]) : undefined;
      final answer = await callFunction(
        callback,
        reduce ? [accumulator, value, index, list] : [value, index, list],
        !reduce && args.length > 1 ? args[1] : undefined,
      );
      switch (name) {
        case 'map':
          result[index] = answer;
        case 'filter':
          if (truthy(answer)) result.add(value);
        case 'reduce':
        case 'reduceRight':
          accumulator = answer;
        case 'find':
          if (truthy(answer)) return value;
        case 'findIndex':
          if (truthy(answer)) return index;
        case 'some':
          if (truthy(answer)) return true;
        case 'every':
          if (!truthy(answer)) return false;
      }
    }
    return switch (name) {
      'map' || 'filter' => result,
      'reduce' || 'reduceRight' => accumulator,
      'findIndex' => -1,
      'some' => false,
      'every' => true,
      _ => undefined,
    };
  }

  Future<dynamic> evaluateBinaryExpression(Node node, Env env) async => binary(
    node['operator'],
    (await evaluate(node['left'], env)),
    (await evaluate(node['right'], env)),
  );

  Future<dynamic> evaluateLogicalExpression(Node node, Env env) async {
    final left = (await evaluate(node['left'], env));
    return switch (node['operator']) {
      '&&' => truthy(left) ? (await evaluate(node['right'], env)) : left,
      '||' => truthy(left) ? left : (await evaluate(node['right'], env)),
      '??' => isNullish(left) ? (await evaluate(node['right'], env)) : left,
      _ => throw JsError('Unsupported logical operator: ${node['operator']}'),
    };
  }

  Future<dynamic> evaluateUnaryExpression(Node node, Env env) async {
    if (node['operator'] == 'typeof' &&
        node['argument']['type'] == 'Identifier' &&
        !env.has(node['argument']['name'])) {
      return 'undefined';
    }
    final argument = (await evaluate(node['argument'], env));
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
            (await evaluate(target['object'], env)),
            target['computed'] == true
                ? (await evaluate(target['property'], env))
                : target['property']['name'],
          );
        }
        return true;
      default:
        throw JsError('Unsupported unary operator: ${node['operator']}');
    }
  }
}

class _AsyncInterpreterFunction implements JsCallable {
  final Node node;
  final Env closure;
  final _AsyncEvaluator interpreter;
  _AsyncInterpreterFunction(this.node, this.closure, this.interpreter);
  @override
  Future<dynamic> invoke(List<dynamic> args, dynamic thisValue) async {
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
            value = (await interpreter.evaluate(param['right'], env));
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
      final result = (await interpreter.evaluate(node['body'], env));
      return node['body']['type'] == 'BlockStatement' ? undefined : result;
    } on _Signal catch (signal) {
      if (signal.kind == 'return') return signal.value;
      rethrow;
    } finally {
      interpreter.currentEnv = previous;
    }
  }
}
