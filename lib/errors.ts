export class InterpreterError extends Error {
  source: string;
  line: number;
  column: number;
  position: number;
  length: number;
  sourceCode?: string;

  constructor(
    message: string,
    source: string,
    line: number,
    column: number,
    position: number,
    sourceCode?: string,
    length = 1,
  ) {
    super(message);

    this.name = "InterpreterError";
    this.source = source;
    this.line = line;
    this.column = column;
    this.position = position;
    this.sourceCode = sourceCode;
    this.length = Number.isFinite(length) ? Math.max(1, Math.trunc(length)) : 1;
  }
}

export function createInterpreterError(
  error: any,
  source: string,
  lineOffset = 0,
  sourceCode?: string,
) {
  if (error instanceof InterpreterError) {
    return error;
  }

  var loc = error?.loc?.start ?? error?.loc;
  var line = (loc?.line ?? error?.line ?? 1) - lineOffset;

  if (line < 1) {
    line = 1;
  }

  var column = loc?.column ?? error?.column ?? 0;

  var position = error?.position ?? error?.pos ?? error?.start ?? loc?.index ?? 0;
  const end = error?.end ?? error?.loc?.end?.index;
  const start = error?.start ?? loc?.index ?? position;
  const length = error?.length ?? (typeof end === "number" ? end - start :
    typeof error?.loc?.end?.column === "number" && error.loc.end.line === loc?.line
      ? error.loc.end.column - column : 1);

  return new InterpreterError(
    error?.message ?? String(error),
    source,
    line,
    column,
    position,
    sourceCode,
    length,
  );
}

export function formatInterpreterError(
  error: InterpreterError,
  sourceCode?: string,
) {
  return [
    `${error.source} error at line ${error.line}`,
    "",
    error.message,
  ].join("\n");
}
