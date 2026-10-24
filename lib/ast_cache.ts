import type parser from "@babel/parser";

type ParsedAst = ReturnType<typeof parser.parse>;

export interface AstCacheStats {
  size: number;
  maxEntries: number;
  hits: number;
  misses: number;
  evictions: number;
}

export type AstJsonValue = null | boolean | number | string | AstJsonValue[] | { [key: string]: AstJsonValue };

export interface AstCacheJSON {
  format: "custom-js-interpreter.ast-cache";
  version: 1;
  parser: "babel-7-script-v1";
  entries: { source: string; ast: AstJsonValue }[];
}

function encodeAst(value: unknown): AstJsonValue {
  if (typeof value === "number" && !Number.isFinite(value)) {
    return { $number: String(value) };
  }
  if (value === null || typeof value === "string" || typeof value === "boolean" || typeof value === "number") return value;
  if (Array.isArray(value)) return value.map(encodeAst);
  if (value && typeof value === "object") {
    // Keep evaluator fields/locations, without Babel-only comments, tokens or raw spelling.
    const omitted = new Set(["comments", "leadingComments", "trailingComments", "innerComments", "tokens", "extra", "errors"]);
    return Object.fromEntries(Object.entries(value)
      .filter(([key, child]) => child !== undefined && !omitted.has(key))
      .map(([key, child]) => [key, encodeAst(child)]));
  }
  throw new TypeError("AST contains a non-JSON value");
}

// Cached nodes can be shared across calls/instances. Keep them read-only so an
// exposed fn.node or parse() result cannot change subsequent executions.
function freezeAst(ast: ParsedAst): ParsedAst {
  const pending: object[] = [ast];
  const visited = new WeakSet<object>();
  while (pending.length) {
    const value = pending.pop()!;
    if (visited.has(value)) continue;
    visited.add(value);
    for (const child of Object.values(value)) {
      if (child !== null && typeof child === "object") pending.push(child);
    }
    Object.freeze(value);
  }
  return ast;
}

/** Bounded LRU of immutable Babel ASTs, keyed by the exact parser source. */
export class AstCache {
  private readonly entries = new Map<string, ParsedAst>();
  private hits = 0;
  private misses = 0;
  private evictions = 0;

  constructor(readonly maxEntries = 100) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) {
      throw new RangeError("AstCache maxEntries must be a positive safe integer");
    }
  }

  get stats(): AstCacheStats {
    return {
      size: this.entries.size,
      maxEntries: this.maxEntries,
      hits: this.hits,
      misses: this.misses,
      evictions: this.evictions,
    };
  }

  /** JSON.stringify(cache) also calls this. Returns a detached, versioned snapshot. */
  toJSON(): AstCacheJSON {
    return {
      format: "custom-js-interpreter.ast-cache",
      version: 1,
      parser: "babel-7-script-v1",
      entries: [...this.entries].map(([source, ast]) => ({ source, ast: encodeAst(ast) })),
    };
  }

  getOrParse(source: string, parseSource: () => ParsedAst): ParsedAst {
    const cached = this.entries.get(source);
    if (cached !== undefined) {
      this.hits++;
      this.entries.delete(source);
      this.entries.set(source, cached);
      return cached;
    }

    this.misses++;
    // Failed parses are never stored. Entries are added only after success.
    const ast = freezeAst(parseSource());
    if (this.entries.size === this.maxEntries) {
      this.entries.delete(this.entries.keys().next().value!);
      this.evictions++;
    }
    this.entries.set(source, ast);
    return ast;
  }

  /** Release cached ASTs and reset counters, without changing runtime state. */
  clear(): void {
    this.entries.clear();
    this.hits = 0;
    this.misses = 0;
    this.evictions = 0;
  }
}
