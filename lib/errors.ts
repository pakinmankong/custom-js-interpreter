export class InterpreterError extends Error {
  source: string;
  line: number;
  column: number;
  position: number;
  sourceCode?: string;

  constructor(
    message: string,
    source: string,
    line: number,
    column: number,
    position: number,
    sourceCode?: string,
  ) {
    super(message);

    this.name = "InterpreterError";
    this.source = source;
    this.line = line;
    this.column = column;
    this.position = position;
    this.sourceCode = sourceCode;
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

  return new InterpreterError(
    error?.message ?? String(error),
    source,
    line,
    column,
    position,
    sourceCode,
  );
}

export function formatInterpreterError(
  error: InterpreterError,
  sourceCode?: string,
) {
  var code = sourceCode ?? error.sourceCode ?? "";

  var lines = code.split(/\r\n|[\n\r\u2028\u2029]/);

  var lineText = lines[error.line - 1] ?? "";

  var pointer = " ".repeat(Math.max(0, error.column)) + "^";

  return [
    `${error.source} error at line ${error.line}, column ${error.column}, position ${error.position}`,
    "",
    `> ${error.line} | ${lineText}`,
    `    | ${pointer}`,
    "",
    error.message,
  ].join("\n");
}
