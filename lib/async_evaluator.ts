import Env from './env.js';
import type InterpreterService from './interpreter_service.js';
import { asyncArrayMethods, callAsyncArrayMethod } from './async_array.js';
import { asyncNative } from './async_native.js';

/** Sequential evaluator used only by executeAsync(). */
export default class AsyncEvaluator {
  constructor(readonly service: InterpreterService) {}
  get context() { return this.service.context; }
  get currentEnv() { return this.service.currentEnv; }
  set currentEnv(env: Env) { this.service.currentEnv = env; }
  get dataResolver() { return this.service.dataResolver; }
  getDataRootName(name: string) { return this.service.getDataRootName(name); }

  async getDataReferencePathAsync(
    node: any,
    env: Env,
  ): Promise<any> {
    if (this.context.resolver !== true) return null;
    if (node.type === "Identifier") {
      var root = this.getDataRootName(node.name);

      if (
        !Object.prototype.hasOwnProperty.call(
          this.context.variables || {},
          root,
        )
      ) {
        return null;
      }

      return {
        root,
        path: [],
      };
    }

    if (
      node.type !== "MemberExpression" &&
      node.type !== "OptionalMemberExpression"
    ) {
      return null;
    }

    var parent = (await this.getDataReferencePathAsync(node.object, env));

    if (parent === null) {
      return null;
    }

    var property: string;

    if (node.computed) {
      property = String((await this.evaluateAsync(node.property, env)));
    } else {
      property = node.property.name;
    }

    return {
      root: parent.root,
      path: [...parent.path, property],
    };
  }

  hoistFunctionsAsync(body: any[], env: Env) {
    for (var node of body) {
      if (node.type === "FunctionDeclaration") {
        var fn = this.createFunctionAsync(node, env);

        env.define(node.id.name, fn);
      }
    }
  }

  createFunctionAsync(node: any, closure: Env) {
    var self = this;

    var fn: any = async function (args: any[], thisValue?: any) {
      var functionEnv = new Env(closure);

      if (node.type !== "ArrowFunctionExpression") {
        functionEnv.define("this", thisValue);
      }

      for (var i = 0; i < node.params.length; i++) {
        var param = node.params[i];

        if (param.type === "Identifier") {
          functionEnv.define(param.name, args[i]);

          continue;
        }

        if (param.type === "AssignmentPattern") {
          if (param.left.type === "Identifier") {
            var value = args[i];

            if (value === undefined) {
              value = (await self.evaluateAsync(param.right, functionEnv));
            }

            functionEnv.define(param.left.name, value);
          }

          continue;
        }

        if (param.type === "RestElement") {
          if (param.argument.type === "Identifier") {
            functionEnv.define(param.argument.name, args.slice(i));
          }

          continue;
        }
      }

      if (node.body && node.body.type === "BlockStatement") {
        self.hoistFunctionsAsync(node.body.body, functionEnv);
      }

      var previousEnv = self.currentEnv;

      self.currentEnv = functionEnv;

      try {
        const result = (await self.evaluateAsync(node.body, functionEnv));
        return node.body.type === "BlockStatement" ? undefined : result;
      } finally {
        self.currentEnv = previousEnv;
      }
    };

    fn.__interpreterFunction = true;

    fn.node = node;

    return fn;
  }

  async callFunctionAsync(fn: any, args: any[], thisValue?: any) : Promise<any> {
    if (fn && fn.__interpreterFunction) {
      try {
        return await fn(args, thisValue);
      } catch (error: any) {
        if (error && error.__returnSignal) {
          return error.value;
        }

        throw error;
      }
    }

    if (typeof fn !== "function") {
      throw new Error("Value is not a function");
    }

    var interpreter = this;

    var nativeArgs = args.map(function (arg: any) {
      if (typeof arg === "function" && arg.__interpreterFunction) {
        return function (this: any, ...callbackArgs: any[]) {
          return interpreter.callFunctionAsync(arg, callbackArgs, this);
        };
      }

      return arg;
    });

    return await (fn[asyncNative] ?? fn).apply(thisValue, nativeArgs);
  }

  async getReferenceValueAsync(node: any, env: Env) : Promise<any> {
    if (node.type === "Identifier") {
      return {
        get: () => env.get(node.name),

        set: (value: any) => env.set(node.name, value),
      };
    }

    if (
      node.type === "MemberExpression" ||
      node.type === "OptionalMemberExpression"
    ) {
      var object = (await this.evaluateAsync(node.object, env));

      if (object === null || object === undefined) {
        throw new Error("Cannot access property of null or undefined");
      }

      var property = node.computed
        ? (await this.evaluateAsync(node.property, env))
        : node.property.name;

      return {
        get: () => object[property],

        set: (value: any) => {
          object[property] = value;

          return value;
        },
      };
    }

    throw new Error("Invalid assignment target");
  }

  async setReferenceValueAsync(node: any, value: any, env: Env) : Promise<any> {
    var reference = (await this.getReferenceValueAsync(node, env));

    return reference.set(value);
  }

  async assignLoopVariableAsync(left: any, value: any, env: Env) : Promise<any> {
    if (left.type === "VariableDeclaration") {
      var declaration = left.declarations[0];

      if (declaration.id.type !== "Identifier") {
        throw new Error("Loop variable must be an identifier");
      }

      if (left.kind === "var") {
        if (!env.has(declaration.id.name)) {
          env.define(declaration.id.name, value);
        } else {
          env.set(declaration.id.name, value);
        }

        return;
      }

      env.define(declaration.id.name, value, left.kind === "const");

      return;
    }

    (await this.setReferenceValueAsync(left, value, env));
  }

  async evaluateAsync(node: any, env: Env): Promise<any> {
    try {
      if (!node) {
        return undefined;
      }

      switch (node.type) {
        case "Program": {
          var programResult;

          for (var statement of node.body) {
            programResult = (await this.evaluateAsync(statement, env));
          }

          return programResult;
        }

        case "BlockStatement": {
          var blockResult;

          for (var statement of node.body) {
            blockResult = (await this.evaluateAsync(statement, env));
          }

          return blockResult;
        }

        case "EmptyStatement":
          return undefined;

        case "ExpressionStatement":
          return (await this.evaluateAsync(node.expression, env));

        case "VariableDeclaration": {
          var declarationResult;

          for (var declaration of node.declarations) {
            var value = declaration.init
              ? (await this.evaluateAsync(declaration.init, env))
              : undefined;

            if (declaration.id.type !== "Identifier") {
              throw new Error("Variable declaration must use an identifier");
            }

            declarationResult = env.define(
              declaration.id.name,
              value,
              node.kind === "const",
            );
          }

          return declarationResult;
        }

        case "FunctionDeclaration": {
          var fn = this.createFunctionAsync(node, env);

          env.define(node.id.name, fn);

          return fn;
        }

        case "FunctionExpression":
          return this.createFunctionAsync(node, env);

        case "ArrowFunctionExpression":
          return this.createFunctionAsync(node, env);

        case "CallExpression":
          return (await this.evaluateCallExpressionAsync(node, env));

        case "ReturnStatement": {
          var returnValue = node.argument
            ? (await this.evaluateAsync(node.argument, env))
            : undefined;

          var returnError: any = new Error("__RETURN__");

          returnError.__returnSignal = true;

          returnError.value = returnValue;

          throw returnError;
        }

        case "Identifier": {
          if (env.has(node.name)) {
            return env.get(node.name);
          }

          var formulaRoot = env.has("__FORMULA_ROOT__")
            ? env.get("__FORMULA_ROOT__")
            : null;

          var formulaPath = env.has("__FORMULA_PATH__")
            ? env.get("__FORMULA_PATH__")
            : null;

          if (this.context.resolver === true && formulaRoot && Array.isArray(formulaPath)) {
            return (await this.dataResolver.resolveLocalAsync(
              node.name,
              formulaRoot,
              formulaPath,
              env,
            ));
          }

          throw new Error(`Undefined variable: ${node.name}`);
        }

        case "NumericLiteral":
          return node.value;

        case "StringLiteral":
          return node.value;

        case "BooleanLiteral":
          return node.value;

        case "NullLiteral":
          return null;

        case "BigIntLiteral":
          return BigInt(node.value);

        case "RegExpLiteral":
          return new RegExp(node.pattern, node.flags);

        case "ArrayExpression": {
          var array: any[] = [];

          for (var element of node.elements) {
            if (element === null) {
              array.push(undefined);

              continue;
            }

            if (element.type === "SpreadElement") {
              var spreadValue = (await this.evaluateAsync(element.argument, env));

              if (
                !spreadValue ||
                typeof spreadValue[Symbol.iterator] !== "function"
              ) {
                throw new Error("Spread argument must be iterable");
              }

              for (var item of spreadValue) {
                array.push(item);
              }

              continue;
            }

            array.push((await this.evaluateAsync(element, env)));
          }

          return array;
        }

        case "ObjectExpression": {
          var object: any = {};

          for (var property of node.properties) {
            if (property.type === "SpreadElement") {
              var spreadObject = (await this.evaluateAsync(property.argument, env));

              Object.assign(object, spreadObject);

              continue;
            }

            var key: any;

            if (property.computed) {
              key = (await this.evaluateAsync(property.key, env));
            } else if (property.key.type === "Identifier") {
              key = property.key.name;
            } else {
              key = property.key.value;
            }

            object[key] = (await this.evaluateAsync(property.value, env));
          }

          return object;
        }

        case "MemberExpression":
        case "OptionalMemberExpression": {
          var dataReference = (await this.getDataReferencePathAsync(node, env));

          if (dataReference !== null) {
            if (dataReference.path.length === 0) {
              return this.dataResolver.variables[dataReference.root];
            }

            return (await this.dataResolver.resolveAsync(
              dataReference.root,
              dataReference.path,
              env,
            ));
          }

          var objectValue = (await this.evaluateAsync(node.object, env));

          if (objectValue === null || objectValue === undefined) {
            if (node.optional) {
              return undefined;
            }

            throw new Error("Cannot read property of null or undefined");
          }

          var property = node.computed
            ? (await this.evaluateAsync(node.property, env))
            : node.property.name;

          return objectValue[property];
        }

        case "AssignmentExpression": {
          var right = (await this.evaluateAsync(node.right, env));

          if (node.operator === "=") {
            return (await this.setReferenceValueAsync(node.left, right, env));
          }

          var reference = (await this.getReferenceValueAsync(node.left, env));

          var current = reference.get();

          var result;

          switch (node.operator) {
            case "+=":
              result = current + right;
              break;

            case "-=":
              result = current - right;
              break;

            case "*=":
              result = current * right;
              break;

            case "/=":
              result = current / right;
              break;

            case "%=":
              result = current % right;
              break;

            case "**=":
              result = current ** right;
              break;

            default:
              throw new Error(
                `Unsupported assignment operator: ${node.operator}`,
              );
          }

          return reference.set(result);
        }

        case "UpdateExpression": {
          var updateReference = (await this.getReferenceValueAsync(node.argument, env));

          var oldValue = updateReference.get();

          var newValue;

          if (node.operator === "++") {
            newValue = oldValue + 1;
          } else if (node.operator === "--") {
            newValue = oldValue - 1;
          } else {
            throw new Error(`Unsupported update operator: ${node.operator}`);
          }

          updateReference.set(newValue);

          return node.prefix ? newValue : oldValue;
        }

        case "BinaryExpression":
          return (await this.evaluateBinaryExpressionAsync(node, env));

        case "LogicalExpression":
          return (await this.evaluateLogicalExpressionAsync(node, env));

        case "UnaryExpression":
          return (await this.evaluateUnaryExpressionAsync(node, env));

        case "ConditionalExpression":
          return (await this.evaluateAsync(node.test, env))
            ? (await this.evaluateAsync(node.consequent, env))
            : (await this.evaluateAsync(node.alternate, env));

        case "IfStatement":
          if ((await this.evaluateAsync(node.test, env))) {
            return (await this.evaluateAsync(node.consequent, env));
          }

          if (node.alternate) {
            return (await this.evaluateAsync(node.alternate, env));
          }

          return undefined;

        case "ForStatement": {
          if (node.init) {
            (await this.evaluateAsync(node.init, env));
          }

          while (node.test ? (await this.evaluateAsync(node.test, env)) : true) {
            try {
              (await this.evaluateAsync(node.body, env));
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                if (node.update) {
                  (await this.evaluateAsync(node.update, env));
                }

                continue;
              }

              throw error;
            }

            if (node.update) {
              (await this.evaluateAsync(node.update, env));
            }
          }

          return undefined;
        }

        case "ForOfStatement": {
          var iterable = (await this.evaluateAsync(node.right, env));

          if (!iterable || typeof iterable[Symbol.iterator] !== "function") {
            throw new Error("Value is not iterable");
          }

          for (var value of iterable) {
            var iterationEnv = node.left.type === "VariableDeclaration" && node.left.kind !== "var"
              ? new Env(env)
              : env;
            (await this.assignLoopVariableAsync(node.left, value, iterationEnv));

            try {
              (await this.evaluateAsync(node.body, iterationEnv));
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                continue;
              }

              throw error;
            }
          }

          return undefined;
        }

        case "ForInStatement": {
          var object = (await this.evaluateAsync(node.right, env));

          if (object === null || object === undefined) {
            return undefined;
          }

          for (var objectKey of Object.keys(object)) {
            var iterationEnv = node.left.type === "VariableDeclaration" && node.left.kind !== "var"
              ? new Env(env)
              : env;
            (await this.assignLoopVariableAsync(node.left, objectKey, iterationEnv));

            try {
              (await this.evaluateAsync(node.body, iterationEnv));
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                continue;
              }

              throw error;
            }
          }

          return undefined;
        }

        case "WhileStatement":
          while ((await this.evaluateAsync(node.test, env))) {
            try {
              (await this.evaluateAsync(node.body, env));
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                continue;
              }

              throw error;
            }
          }

          return undefined;

        case "DoWhileStatement":
          do {
            try {
              (await this.evaluateAsync(node.body, env));
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                continue;
              }

              throw error;
            }
          } while ((await this.evaluateAsync(node.test, env)));

          return undefined;

        case "BreakStatement": {
          var breakError: any = new Error("__BREAK__");

          breakError.__breakSignal = true;

          throw breakError;
        }

        case "ContinueStatement": {
          var continueError: any = new Error("__CONTINUE__");

          continueError.__continueSignal = true;

          throw continueError;
        }

        case "SequenceExpression": {
          var sequenceResult;

          for (var expression of node.expressions) {
            sequenceResult = (await this.evaluateAsync(expression, env));
          }

          return sequenceResult;
        }

        case "ThisExpression":
          return env.get("this");

        case "TemplateLiteral": {
          var template = "";

          for (var i = 0; i < node.quasis.length; i++) {
            template += node.quasis[i].value.cooked;

            if (i < node.expressions.length) {
              template += (await this.evaluateAsync(node.expressions[i], env));
            }
          }

          return template;
        }

        case "SpreadElement":
          return (await this.evaluateAsync(node.argument, env));

        case "ParenthesizedExpression":
          return (await this.evaluateAsync(node.expression, env));

        default:
          throw new Error(`Unknown node type: ${node.type}`);
      }
    } catch (error: any) {
      if (!error.loc && node.loc) {
        error.loc = node.loc;
      }

      if (error.pos === undefined && node.start !== undefined) {
        error.pos = node.start;
      }

      throw error;
    }
  }

  async evaluateCallExpressionAsync(node: any, env: Env) : Promise<any> {
    var thisValue = undefined;

    var fn;
    var functionName = "<anonymous>";

    if (
      node.callee.type === "MemberExpression" ||
      node.callee.type === "OptionalMemberExpression"
    ) {
      thisValue = (await this.evaluateAsync(node.callee.object, env));

      if (thisValue === null || thisValue === undefined) {
        if (node.callee.optional) {
          return undefined;
        }

        throw new Error("Cannot call method of null or undefined");
      }

      var property = node.callee.computed
        ? (await this.evaluateAsync(node.callee.property, env))
        : node.callee.property.name;

      functionName = String(property);

      fn = thisValue[property];
    } else {
      if (node.callee.type === "Identifier") {
        functionName = node.callee.name;

        if (!env.has(functionName)) {
          throw new Error(`Undefined function: ${functionName}()`);
        }
      }

      fn = (await this.evaluateAsync(node.callee, env));
    }

    if (fn === undefined || fn === null) {
      throw new Error(`Undefined function: ${functionName}()`);
    }

    if (typeof fn !== "function" && !fn.__interpreterFunction) {
      throw new Error(`${functionName} is not a function`);
    }

    var args: any[] = [];

    for (var argument of node.arguments) {
      if (argument.type === "SpreadElement") {
        var spreadValue = (await this.evaluateAsync(argument.argument, env));

        if (
          !spreadValue ||
          typeof spreadValue[Symbol.iterator] !== "function"
        ) {
          throw new Error("Spread argument must be iterable");
        }

        for (var value of spreadValue) {
          args.push(value);
        }

        continue;
      }

      args.push((await this.evaluateAsync(argument, env)));
    }

    if (Array.isArray(thisValue) && asyncArrayMethods.has(functionName) &&
        fn === (Array.prototype as any)[functionName] &&
        (functionName !== 'sort' || args[0] !== undefined)) {
      return await callAsyncArrayMethod(thisValue, functionName, args,
        (callback, values, receiver) => this.callFunctionAsync(callback, values, receiver));
    }
    if (typeof thisValue === 'string' && typeof args[1] === 'function' &&
        (functionName === 'replace' || functionName === 'replaceAll') &&
        fn === (String.prototype as any)[functionName]) {
      const matches: any[][] = [];
      fn.call(thisValue, args[0], (...values: any[]) => { matches.push(values); return values[0]; });
      let text = '', end = 0;
      for (const values of matches) {
        const offset = values[typeof values[values.length - 1] === 'object' ? values.length - 3 : values.length - 2];
        text += thisValue.slice(end, offset) + String(await this.callFunctionAsync(args[1], values, undefined));
        end = offset + values[0].length;
      }
      return text + thisValue.slice(end);
    }
    return (await this.callFunctionAsync(fn, args, thisValue));
  }

  async evaluateBinaryExpressionAsync(node: any, env: Env) : Promise<any> {
    var left = (await this.evaluateAsync(node.left, env));

    var right = (await this.evaluateAsync(node.right, env));

    switch (node.operator) {
      case "+":
        return left + right;

      case "-":
        return left - right;

      case "*":
        return left * right;

      case "/":
        return left / right;

      case "%":
        return left % right;

      case "**":
        return left ** right;

      case "==":
        return left == right;

      case "!=":
        return left != right;

      case "===":
        return left === right;

      case "!==":
        return left !== right;

      case "<":
        return left < right;

      case "<=":
        return left <= right;

      case ">":
        return left > right;

      case ">=":
        return left >= right;

      case "in":
        return left in right;

      case "instanceof":
        return left instanceof right;

      default:
        throw new Error(`Unsupported binary operator: ${node.operator}`);
    }
  }

  async evaluateLogicalExpressionAsync(node: any, env: Env) : Promise<any> {
    var left = (await this.evaluateAsync(node.left, env));

    if (node.operator === "&&") {
      return left ? (await this.evaluateAsync(node.right, env)) : left;
    }

    if (node.operator === "||") {
      return left ? left : (await this.evaluateAsync(node.right, env));
    }

    if (node.operator === "??") {
      return left !== null && left !== undefined
        ? left
        : (await this.evaluateAsync(node.right, env));
    }

    throw new Error(`Unsupported logical operator: ${node.operator}`);
  }

  async evaluateUnaryExpressionAsync(node: any, env: Env) : Promise<any> {
    if (node.operator === "typeof" && node.argument.type === "Identifier" && !env.has(node.argument.name)) {
      return "undefined";
    }
    var argument = (await this.evaluateAsync(node.argument, env));

    switch (node.operator) {
      case "+":
        return +argument;

      case "-":
        return -argument;

      case "!":
        return !argument;

      case "~":
        return ~argument;

      case "typeof":
        return typeof argument;

      case "void":
        return undefined;

      case "delete": {
        if (
          node.argument.type === "MemberExpression" ||
          node.argument.type === "OptionalMemberExpression"
        ) {
          var object = (await this.evaluateAsync(node.argument.object, env));

          var property = node.argument.computed
            ? (await this.evaluateAsync(node.argument.property, env))
            : node.argument.property.name;

          return delete object[property];
        }

        return true;
      }

      default:
        throw new Error(`Unsupported unary operator: ${node.operator}`);
    }
  }
}
