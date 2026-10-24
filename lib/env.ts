export default class Env {
  vars: Record<string, any>;
  parent: Env | null;
  constants: Set<string>;

  constructor(parent: Env | null = null) {
    this.vars = {};
    this.parent = parent;
    this.constants = new Set();
  }

  hasOwn(name: string) {
    return Object.prototype.hasOwnProperty.call(this.vars, name);
  }

  has(name: string): boolean {
    if (this.hasOwn(name)) {
      return true;
    }

    if (this.parent) {
      return this.parent.has(name);
    }

    return false;
  }

  define(name: string, value: any, constant = false) {
    if (this.constants.has(name)) {
      throw new TypeError(`Assignment to constant variable: ${name}`);
    }

    this.vars[name] = value;
    if (constant) {
      this.constants.add(name);
    }

    return value;
  }

  get(name: string): any {
    if (this.hasOwn(name)) {
      return this.vars[name];
    }

    if (this.parent) {
      return this.parent.get(name);
    }

    throw new Error(`Undefined identifier: ${name}`);
  }

  set(name: string, value: any): any {
    if (this.hasOwn(name)) {
      if (this.constants.has(name)) {
        throw new TypeError(`Assignment to constant variable: ${name}`);
      }

      this.vars[name] = value;

      return value;
    }

    if (this.parent && this.parent.has(name)) {
      return this.parent.set(name, value);
    }

    throw new Error(`Undefined variable: ${name}`);
  }
}
