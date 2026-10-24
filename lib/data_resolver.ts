import type InterpreterService from "./interpreter_service.js";
import Env from "./env.js";
import { createInterpreterError } from "./errors.js";

export default class DataResolver {
  interpreter: InterpreterService;
  variables: Record<string, any>;

  cache: Map<string, any>;
  evaluating: string[];

  constructor(interpreter: InterpreterService, variables: Record<string, any>) {
    this.interpreter = interpreter;
    this.variables = variables;
    this.cache = new Map();
    this.evaluating = [];
  }

  clearCache() {
    this.cache.clear();
  }

  resolve(rootName: string, path: string[], env: Env) {
    var key = [rootName, ...path].join(".");

    if (this.cache.has(key)) {
      return this.cache.get(key);
    }

    if (this.evaluating.includes(key)) {
      var index = this.evaluating.indexOf(key);

      var cycle = this.evaluating.slice(index).concat(key).join(" -> ");

      throw new Error(`Circular dependency: ${cycle}`);
    }

    if (!Object.prototype.hasOwnProperty.call(this.variables, rootName)) {
      throw new Error(`Undefined data source: ${rootName}`);
    }

    var root = this.variables[rootName];

    var node = this.find(root, path);

    if (node === undefined) {
      throw new Error(`Undefined reference: ${[rootName, ...path].join(".")}`);
    }

    // Plain strings are data. Keep legacy statement-based formulas, while
    // { formula: ... } explicitly identifies arbitrary executable source.
    if (typeof node === "string" && this.isLegacyFormula(node)) {
      return this.evaluateFormula(key, node, rootName, path, env);
    }

    if (node && typeof node === "object" && typeof node.formula === "string") {
      return this.evaluateFormula(key, node.formula, rootName, path, env);
    }

    this.cache.set(key, node);

    return node;
  }

  private isLegacyFormula(value: string): boolean {
    return /^(?:\s|\/\/[^\r\n\u2028\u2029]*(?:[\r\n\u2028\u2029]|$)|\/\*[\s\S]*?\*\/|#[Cc][Uu][Rr][Rr][Ee][Nn][Tt]_[Rr][Oo][Ww][^\r\n\u2028\u2029]*(?:[\r\n\u2028\u2029]|$))*(?:return|var|let|const|function|if|for|while|do|switch|try|throw)\b/.test(value);
  }

  resolveLocal(name: string, rootName: string, path: string[], env: Env) {
    var parentPath = path.slice(0, -1);

    var root = this.variables[rootName];

    var parent = this.find(root, parentPath);

    if (parent === undefined || parent === null) {
      throw new Error(`Undefined variable: ${name}`);
    }

    /*
     * Normal object:
     *
     * {
     *   A: formula,
     *   B: formula
     * }
     */
    if (typeof parent === "object" && !Array.isArray(parent)) {
      if (Object.prototype.hasOwnProperty.call(parent, name)) {
        return this.resolve(rootName, [...parentPath, name], env);
      }

      /*
       * RESULTS / columns object
       *
       * columns: {
       *   A: formula,
       *   B: formula
       * }
       */
      if (
        parent.columns &&
        typeof parent.columns === "object" &&
        !Array.isArray(parent.columns) &&
        Object.prototype.hasOwnProperty.call(parent.columns, name)
      ) {
        return this.resolve(rootName, [...parentPath, "columns", name], env);
      }

      /*
       * children
       */
      if (
        parent.children &&
        Object.prototype.hasOwnProperty.call(parent.children, name)
      ) {
        return this.resolve(rootName, [...parentPath, "children", name], env);
      }
    }

    /*
     * columns array
     *
     * columns: [
     *   {
     *     name: 'A',
     *     formula: '...'
     *   }
     * ]
     */
    if (parent && Array.isArray(parent.columns)) {
      var columnIndex = parent.columns.findIndex(function (item: any) {
        return item && item.name === name;
      });

      if (columnIndex !== -1) {
        return this.resolve(
          rootName,
          [...parentPath, "columns", String(columnIndex)],
          env,
        );
      }
    }

    /*
     * Current parent itself may be an array
     *
     * GROUP1: [
     *   { name: 'A', formula: '...' },
     *   { name: 'B', formula: '...' }
     * ]
     */
    if (Array.isArray(parent)) {
      var itemIndex = parent.findIndex(function (item: any) {
        return item && typeof item === "object" && item.name === name;
      });

      if (itemIndex !== -1) {
        return this.resolve(rootName, [...parentPath, String(itemIndex)], env);
      }
    }

    throw new Error(`Undefined variable: ${name}`);
  }

  evaluateFormula(
    key: string,
    formula: string,
    rootName: string,
    path: string[],
    env: Env,
  ) {
    this.evaluating.push(key);

    try {
      var value = this.interpreter.evaluateFormula(
        formula,
        rootName,
        path,
        env,
      );

      this.cache.set(key, value);

      return value;
    } catch (error) {
      throw createInterpreterError(error, key, 1, formula);
    } finally {
      this.evaluating.pop();
    }
  }

  find(current: any, path: string[]) {
    for (var i = 0; i < path.length; i++) {
      var part = path[i];

      if (current === null || current === undefined) {
        return undefined;
      }

      if (Array.isArray(current)) {
        var index = Number(part);

        if (Number.isInteger(index) && index >= 0 && index < current.length) {
          current = current[index];
          continue;
        }

        var namedItem = current.find(function (item: any) {
          return item && typeof item === "object" && item.name === part;
        });

        if (namedItem !== undefined) {
          current = namedItem;
          continue;
        }

        return undefined;
      }

      if (Object.prototype.hasOwnProperty.call(current, part)) {
        current = current[part];
        continue;
      }

      /*
       * columns array
       */
      if (Array.isArray(current.columns)) {
        var column = current.columns.find(function (item: any) {
          return item && item.name === part;
        });

        if (column !== undefined) {
          current = column;
          continue;
        }
      }

      /*
       * columns object
       */
      if (
        current.columns &&
        typeof current.columns === "object" &&
        !Array.isArray(current.columns) &&
        Object.prototype.hasOwnProperty.call(current.columns, part)
      ) {
        current = current.columns[part];

        continue;
      }

      /*
       * children
       */
      if (
        current.children &&
        Object.prototype.hasOwnProperty.call(current.children, part)
      ) {
        current = current.children[part];

        continue;
      }

      return undefined;
    }

    return current;
  }
}
