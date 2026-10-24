import parser from "@babel/parser";
import Env from "./env.js";
import DataResolver from "./data_resolver.js";
import { AstCache } from "./ast_cache.js";

export interface InterpreterContext {
  variables?: Record<string, any>;
  functions?: Record<string, any>;
  code?: string;
  /** Default: a per-instance 100-entry cache. Use false to disable or share an AstCache. */
  astCache?: AstCache | false;
}

export default class InterpreterService {
  context: InterpreterContext;

  globalEnv: Env;
  currentEnv: Env;

  dataResolver: DataResolver;
  readonly astCache: AstCache | null;

  userCode: string;
  lineOffset: number;

  reservedWords: Set<string>;

  constructor(context: InterpreterContext = {}) {
    this.context = context;
    this.astCache = context.astCache === false ? null : context.astCache ?? new AstCache();

    this.userCode = context.code || "";

    this.lineOffset = 0;

    this.globalEnv = new Env();
    this.currentEnv = this.globalEnv;

    this.reservedWords = new Set([
      "var",
      "let",
      "const",
      "function",
      "return",
      "if",
      "else",
      "for",
      "while",
      "do",
      "switch",
      "case",
      "default",
      "break",
      "continue",
      "throw",
      "true",
      "false",
      "null",
      "undefined",
      "this",
      "new",
      "typeof",
      "void",
      "delete",
      "in",
      "instanceof",
    ]);

    if (context.variables) {
      for (var key of Object.keys(context.variables)) {
        this.globalEnv.define(key, context.variables[key]);
      }
    }

    if (context.functions) {
      for (var key of Object.keys(context.functions)) {
        this.globalEnv.define(key, context.functions[key]);
      }
    }

    this.dataResolver = new DataResolver(this, context.variables || {});

    this.registerBuiltins();
  }

  registerBuiltins() {
    // existing built-ins
  }

  parse(source: string) {
    const parseSource = () => parser.parse(this.expandRowDirective(source), {
      sourceType: "script",

      plugins: [
        "objectRestSpread",
        "optionalChaining",
        "nullishCoalescingOperator",
      ],

      allowReturnOutsideFunction: true,
    });

    return this.astCache ? this.astCache.getOrParse(source, parseSource) : parseSource();
  }

  /** Remove legacy metadata without changing offsets or literal contents. */
  private expandRowDirective(source: string): string {
    const chars = source.split("");
    const stack: { mode: string; depth: number }[] = [{ mode: "code", depth: 0 }];
    let lineStart = 0;
    for (let i = 0; i < source.length; i++) {
      const c = source[i], next = source[i + 1];
      if ("\r\n\u2028\u2029".includes(c)) lineStart = i + 1;
      const frame = stack[stack.length - 1];
      if (frame.mode === "line") {
        if ("\r\n\u2028\u2029".includes(c)) stack.pop();
        continue;
      }
      if (frame.mode === "block") {
        if (c === "*" && next === "/") { stack.pop(); i++; }
        continue;
      }
      if (frame.mode !== "code") {
        if (c === "\\") { i++; continue; }
        if (c === frame.mode) { stack.pop(); continue; }
        if (frame.mode === "`" && c === "$" && next === "{") {
          stack.push({ mode: "code", depth: 1 }); i++;
        }
        continue;
      }
      if (c === "#" && /^[\t ]*$/.test(source.slice(lineStart, i))) {
        const match = /^#CURRENT_ROW[\t ]*=[\t ]*(?:\d+(?:[\t ]*,[\t ]*\d+)*)?[\t ]*;?[\t ]*(?:\/\/[^\r\n\u2028\u2029]*)?(?=[\r\n\u2028\u2029]|$)/i.exec(source.slice(i));
        if (match) {
          for (let j = i; j < i + match[0].length; j++) chars[j] = " ";
          i += match[0].length - 1;
          continue;
        }
      }
      if (c === "/" && (next === "/" || next === "*")) {
        stack.push({ mode: next === "/" ? "line" : "block", depth: 0 }); i++;
      } else if (c === "\"" || c === "'" || c === "`") {
        stack.push({ mode: c, depth: 0 });
      } else if (frame.depth > 0) {
        if (c === "{") frame.depth++;
        if (c === "}" && --frame.depth === 0) stack.pop();
      }
    }
    return chars.join("");
  }

  clearAstCache() {
    this.astCache?.clear();
  }

  exportAstCache() {
    if (!this.astCache) throw new Error("AST cache is disabled");
    return this.astCache.toJSON();
  }

  /** Parse/cache a main entry without evaluating it or creating runtime state. */
  compile(code: string = this.userCode) {
    return this.parse(["function __USER_MAIN__() {", code, "}"].join("\n"));
  }

  /** Prepare a formula, including formulas in branches not executed on the server. */
  compileFormula(formula: string) {
    return this.parse(["function __FORMULA__() {", formula, "}"].join("\n"));
  }

  execute(code: string = this.userCode) {
    this.userCode = code;

    this.lineOffset = 1;

    var ast = this.compile(code);

    var functionNode = ast.program.body[0];

    if (functionNode?.type !== "FunctionDeclaration") {
      throw new Error(
        "Expected user code wrapper to be a function declaration",
      );
    }

    this.hoistFunctions(functionNode.body.body, this.globalEnv);

    var fn = this.createFunction(functionNode, this.globalEnv);

    return this.callFunction(fn, [], undefined);
  }

  evaluateFormula(formula: string, rootName: string, path: string[], env: Env) {
    var ast = this.compileFormula(formula);

    var functionNode = ast.program.body[0];

    var formulaEnv = new Env(env);

    formulaEnv.define("__FORMULA_ROOT__", rootName);

    formulaEnv.define("__FORMULA_PATH__", path);

    var fn = this.createFunction(functionNode, formulaEnv);

    return this.callFunction(fn, [], undefined);
  }

  getDataRootName(name: string) {
    /*
     * Allow:
     *
     * RECORDS.A
     *
     * to access:
     *
     * _RECORDS_.A
     */
    if (name === "RECORDS") {
      return "_RECORDS_";
    }

    return name;
  }

  getDataReferencePath(
    node: any,
    env: Env,
  ): {
    root: string;
    path: string[];
  } | null {
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

    var parent = this.getDataReferencePath(node.object, env);

    if (parent === null) {
      return null;
    }

    var property: string;

    if (node.computed) {
      property = String(this.evaluate(node.property, env));
    } else {
      property = node.property.name;
    }

    return {
      root: parent.root,
      path: [...parent.path, property],
    };
  }

  hoistFunctions(body: any[], env: Env) {
    for (var node of body) {
      if (node.type === "FunctionDeclaration") {
        var fn = this.createFunction(node, env);

        env.define(node.id.name, fn);
      }
    }
  }

  createFunction(node: any, closure: Env) {
    var self = this;

    var fn: any = function (args: any[], thisValue?: any) {
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
              value = self.evaluate(param.right, functionEnv);
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
        self.hoistFunctions(node.body.body, functionEnv);
      }

      var previousEnv = self.currentEnv;

      self.currentEnv = functionEnv;

      try {
        return self.evaluate(node.body, functionEnv);
      } finally {
        self.currentEnv = previousEnv;
      }
    };

    fn.__interpreterFunction = true;

    fn.node = node;

    return fn;
  }

  callFunction(fn: any, args: any[], thisValue?: any) {
    if (fn && fn.__interpreterFunction) {
      try {
        return fn(args, thisValue);
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
          return interpreter.callFunction(arg, callbackArgs, this);
        };
      }

      return arg;
    });

    return fn.apply(thisValue, nativeArgs);
  }

  getReferenceValue(node: any, env: Env) {
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
      var object = this.evaluate(node.object, env);

      if (object === null || object === undefined) {
        throw new Error("Cannot access property of null or undefined");
      }

      var property = node.computed
        ? this.evaluate(node.property, env)
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

  setReferenceValue(node: any, value: any, env: Env) {
    var reference = this.getReferenceValue(node, env);

    return reference.set(value);
  }

  assignLoopVariable(left: any, value: any, env: Env) {
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

    this.setReferenceValue(left, value, env);
  }

  evaluate(node: any, env: Env): any {
    try {
      if (!node) {
        return undefined;
      }

      switch (node.type) {
        case "Program": {
          var programResult;

          for (var statement of node.body) {
            programResult = this.evaluate(statement, env);
          }

          return programResult;
        }

        case "BlockStatement": {
          var blockResult;

          for (var statement of node.body) {
            blockResult = this.evaluate(statement, env);
          }

          return blockResult;
        }

        case "EmptyStatement":
          return undefined;

        case "ExpressionStatement":
          return this.evaluate(node.expression, env);

        case "VariableDeclaration": {
          var declarationResult;

          for (var declaration of node.declarations) {
            var value = declaration.init
              ? this.evaluate(declaration.init, env)
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
          var fn = this.createFunction(node, env);

          env.define(node.id.name, fn);

          return fn;
        }

        case "FunctionExpression":
          return this.createFunction(node, env);

        case "ArrowFunctionExpression":
          return this.createFunction(node, env);

        case "CallExpression":
          return this.evaluateCallExpression(node, env);

        case "ReturnStatement": {
          var returnValue = node.argument
            ? this.evaluate(node.argument, env)
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

          if (formulaRoot && Array.isArray(formulaPath)) {
            return this.dataResolver.resolveLocal(
              node.name,
              formulaRoot,
              formulaPath,
              env,
            );
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
              var spreadValue = this.evaluate(element.argument, env);

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

            array.push(this.evaluate(element, env));
          }

          return array;
        }

        case "ObjectExpression": {
          var object: any = {};

          for (var property of node.properties) {
            if (property.type === "SpreadElement") {
              var spreadObject = this.evaluate(property.argument, env);

              Object.assign(object, spreadObject);

              continue;
            }

            var key: any;

            if (property.computed) {
              key = this.evaluate(property.key, env);
            } else if (property.key.type === "Identifier") {
              key = property.key.name;
            } else {
              key = property.key.value;
            }

            object[key] = this.evaluate(property.value, env);
          }

          return object;
        }

        case "MemberExpression":
        case "OptionalMemberExpression": {
          var dataReference = this.getDataReferencePath(node, env);

          if (dataReference !== null) {
            if (dataReference.path.length === 0) {
              return this.dataResolver.variables[dataReference.root];
            }

            return this.dataResolver.resolve(
              dataReference.root,
              dataReference.path,
              env,
            );
          }

          var objectValue = this.evaluate(node.object, env);

          if (objectValue === null || objectValue === undefined) {
            if (node.optional) {
              return undefined;
            }

            throw new Error("Cannot read property of null or undefined");
          }

          var property = node.computed
            ? this.evaluate(node.property, env)
            : node.property.name;

          return objectValue[property];
        }

        case "AssignmentExpression": {
          var right = this.evaluate(node.right, env);

          if (node.operator === "=") {
            return this.setReferenceValue(node.left, right, env);
          }

          var reference = this.getReferenceValue(node.left, env);

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
          var updateReference = this.getReferenceValue(node.argument, env);

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
          return this.evaluateBinaryExpression(node, env);

        case "LogicalExpression":
          return this.evaluateLogicalExpression(node, env);

        case "UnaryExpression":
          return this.evaluateUnaryExpression(node, env);

        case "ConditionalExpression":
          return this.evaluate(node.test, env)
            ? this.evaluate(node.consequent, env)
            : this.evaluate(node.alternate, env);

        case "IfStatement":
          if (this.evaluate(node.test, env)) {
            return this.evaluate(node.consequent, env);
          }

          if (node.alternate) {
            return this.evaluate(node.alternate, env);
          }

          return undefined;

        case "ForStatement": {
          if (node.init) {
            this.evaluate(node.init, env);
          }

          while (node.test ? this.evaluate(node.test, env) : true) {
            try {
              this.evaluate(node.body, env);
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                if (node.update) {
                  this.evaluate(node.update, env);
                }

                continue;
              }

              throw error;
            }

            if (node.update) {
              this.evaluate(node.update, env);
            }
          }

          return undefined;
        }

        case "ForOfStatement": {
          var iterable = this.evaluate(node.right, env);

          if (!iterable || typeof iterable[Symbol.iterator] !== "function") {
            throw new Error("Value is not iterable");
          }

          for (var value of iterable) {
            var iterationEnv = node.left.type === "VariableDeclaration" && node.left.kind !== "var"
              ? new Env(env)
              : env;
            this.assignLoopVariable(node.left, value, iterationEnv);

            try {
              this.evaluate(node.body, iterationEnv);
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
          var object = this.evaluate(node.right, env);

          if (object === null || object === undefined) {
            return undefined;
          }

          for (var objectKey of Object.keys(object)) {
            var iterationEnv = node.left.type === "VariableDeclaration" && node.left.kind !== "var"
              ? new Env(env)
              : env;
            this.assignLoopVariable(node.left, objectKey, iterationEnv);

            try {
              this.evaluate(node.body, iterationEnv);
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
          while (this.evaluate(node.test, env)) {
            try {
              this.evaluate(node.body, env);
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
              this.evaluate(node.body, env);
            } catch (error: any) {
              if (error && error.__breakSignal) {
                break;
              }

              if (error && error.__continueSignal) {
                continue;
              }

              throw error;
            }
          } while (this.evaluate(node.test, env));

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
            sequenceResult = this.evaluate(expression, env);
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
              template += this.evaluate(node.expressions[i], env);
            }
          }

          return template;
        }

        case "SpreadElement":
          return this.evaluate(node.argument, env);

        case "ParenthesizedExpression":
          return this.evaluate(node.expression, env);

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

  evaluateCallExpression(node: any, env: Env) {
    var thisValue = undefined;

    var fn;
    var functionName = "<anonymous>";

    if (
      node.callee.type === "MemberExpression" ||
      node.callee.type === "OptionalMemberExpression"
    ) {
      thisValue = this.evaluate(node.callee.object, env);

      if (thisValue === null || thisValue === undefined) {
        if (node.callee.optional) {
          return undefined;
        }

        throw new Error("Cannot call method of null or undefined");
      }

      var property = node.callee.computed
        ? this.evaluate(node.callee.property, env)
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

      fn = this.evaluate(node.callee, env);
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
        var spreadValue = this.evaluate(argument.argument, env);

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

      args.push(this.evaluate(argument, env));
    }

    return this.callFunction(fn, args, thisValue);
  }

  evaluateBinaryExpression(node: any, env: Env) {
    var left = this.evaluate(node.left, env);

    var right = this.evaluate(node.right, env);

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

  evaluateLogicalExpression(node: any, env: Env) {
    var left = this.evaluate(node.left, env);

    if (node.operator === "&&") {
      return left ? this.evaluate(node.right, env) : left;
    }

    if (node.operator === "||") {
      return left ? left : this.evaluate(node.right, env);
    }

    if (node.operator === "??") {
      return left !== null && left !== undefined
        ? left
        : this.evaluate(node.right, env);
    }

    throw new Error(`Unsupported logical operator: ${node.operator}`);
  }

  evaluateUnaryExpression(node: any, env: Env) {
    if (node.operator === "typeof" && node.argument.type === "Identifier" && !env.has(node.argument.name)) {
      return "undefined";
    }
    var argument = this.evaluate(node.argument, env);

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
          var object = this.evaluate(node.argument.object, env);

          var property = node.argument.computed
            ? this.evaluate(node.argument.property, env)
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
