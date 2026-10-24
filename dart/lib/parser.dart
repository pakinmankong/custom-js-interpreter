import 'errors.dart';
import 'template.dart';

typedef Node = Map<String, dynamic>;

class Token {
  final String text;
  final String kind;
  final dynamic value;
  final int start, line, column, endLine;
  Token(
    this.text,
    this.kind,
    this.value,
    this.start,
    this.line,
    this.column,
    this.endLine,
  );
}

bool _isLineTerminator(String character) =>
    character == '\n' ||
    character == '\r' ||
    character == '\u2028' ||
    character == '\u2029';

/// Parser for the syntax evaluated by InterpreterService, not a full ECMAScript parser.
class JsParser {
  final String source;
  final List<Token> tokens = [];
  int cursor = 0;
  JsParser(this.source) {
    _tokenize();
  }
  Token get token => tokens[cursor];
  bool at(String text) => token.text == text;
  bool take(String text) {
    if (!at(text)) return false;
    cursor++;
    return true;
  }

  Token expect(String text) {
    final t = token;
    if (!take(text)) fail('Expected "$text", got "${token.text}"');
    return t;
  }

  Never fail(String message) => throw JsError(
    message,
    line: token.line,
    column: token.column,
    position: token.start,
    length: token.kind == 'eof' ? 1 : token.text.length,
  );
  Node node(String type, Token t, [Map<String, dynamic> fields = const {}]) => {
    'type': type,
    'start': t.start,
    'end': cursor > 0 && tokens[cursor - 1].start >= t.start
        ? tokens[cursor - 1].start + tokens[cursor - 1].text.length
        : t.start + t.text.length,
    'line': t.line,
    'column': t.column,
    ...fields,
  };

  void _tokenize() {
    int i = 0, line = 1, column = 0;
    void advance() {
      if (_isLineTerminator(source[i])) {
        // CRLF is one line break, as in Babel/JavaScript ASI.
        if (source[i] != '\n' || i == 0 || source[i - 1] != '\r') line++;
        column = 0;
      } else {
        column++;
      }
      i++;
    }

    const operators = [
      '===',
      '!==',
      '**=',
      '...',
      '=>',
      '==',
      '!=',
      '<=',
      '>=',
      '++',
      '--',
      '+=',
      '-=',
      '*=',
      '/=',
      '%=',
      '**',
      '&&',
      '||',
      '??',
      '?.',
    ];
    while (i < source.length) {
      final c = source[i];
      if (RegExp(r'\s').hasMatch(c)) {
        advance();
        continue;
      }
      if (source.startsWith('//', i)) {
        while (i < source.length && !_isLineTerminator(source[i])) {
          advance();
        }
        continue;
      }
      if (source.startsWith('/*', i)) {
        advance();
        advance();
        while (i < source.length && !source.startsWith('*/', i)) {
          advance();
        }
        if (i >= source.length)
          throw JsError(
            'Unterminated comment',
            line: line,
            column: column,
            position: i,
          );
        advance();
        advance();
        continue;
      }
      final start = i, startLine = line, startColumn = column;
      String kind = 'symbol';
      dynamic value;
      if (c == '/' &&
          (tokens.isEmpty ||
              [
                '=',
                '(',
                '[',
                '{',
                ',',
                ':',
                ';',
                'return',
                '=>',
                '!',
                '&&',
                '||',
                '??',
              ].contains(tokens.last.text))) {
        kind = 'regexp';
        advance();
        final pattern = StringBuffer();
        var inClass = false;
        while (i < source.length) {
          if (source[i] == r'\') {
            pattern.write(source[i]);
            advance();
            if (i < source.length) {
              pattern.write(source[i]);
              advance();
            }
            continue;
          }
          if (source[i] == '[') inClass = true;
          if (source[i] == ']') inClass = false;
          if (source[i] == '/' && !inClass) break;
          if (_isLineTerminator(source[i]))
            throw JsError('Unterminated regular expression');
          pattern.write(source[i]);
          advance();
        }
        if (i >= source.length)
          throw JsError('Unterminated regular expression');
        advance();
        final flags = StringBuffer();
        while (i < source.length && RegExp(r'[a-zA-Z]').hasMatch(source[i])) {
          flags.write(source[i]);
          advance();
        }
        if (flags.toString().split('').any((f) => !'gimsuy'.contains(f)))
          throw JsError('Unsupported regular expression flag: $flags');
        value = {'pattern': pattern.toString(), 'flags': flags.toString()};
      } else if (c == '`') {
        kind = 'template';
        final template = scanTemplate(source, i);
        while (i < template.end) {
          advance();
        }
        value = {'parts': template.parts, 'expressions': template.expressions};
      } else if (c == '"' || c == "'") {
        kind = c == '`' ? 'template' : 'string';
        advance();
        final buffer = StringBuffer();
        while (i < source.length && source[i] != c) {
          if (source[i] == r'\') {
            advance();
            if (i >= source.length) break;
            if (_isLineTerminator(source[i])) {
              final cr = source[i] == '\r';
              advance();
              if (cr && i < source.length && source[i] == '\n') advance();
              continue;
            }
            const escapes = {
              'n': '\n',
              'r': '\r',
              't': '\t',
              'b': '\b',
              'f': '\f',
              'v': '\v',
              '0': '\x00',
            };
            if (source[i] == 'u' || source[i] == 'x') {
              final count = source[i] == 'u' ? 4 : 2;
              advance();
              if (i + count > source.length) throw JsError('Invalid escape');
              final hex = source.substring(i, i + count);
              final code = int.tryParse(hex, radix: 16);
              if (code == null) throw JsError('Invalid escape');
              buffer.writeCharCode(code);
              for (var n = 0; n < count; n++) {
                advance();
              }
              continue;
            }
            buffer.write(escapes[source[i]] ?? source[i]);
            advance();
          } else {
            if (source[i] == '\n' || source[i] == '\r')
              throw JsError(
                'Unterminated string',
                line: startLine,
                column: startColumn,
                position: start,
              );
            buffer.write(source[i]);
            advance();
          }
        }
        if (i >= source.length)
          throw JsError(
            'Unterminated string',
            line: startLine,
            column: startColumn,
            position: start,
          );
        advance();
        value = buffer.toString();
      } else if (RegExp(r'[0-9]').hasMatch(c) ||
          (c == '.' &&
              i + 1 < source.length &&
              RegExp(r'[0-9]').hasMatch(source[i + 1]))) {
        kind = 'number';
        final match = RegExp(
          r'^(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)(?:n)?',
        ).firstMatch(source.substring(i))!;
        final text = match.group(0)!;
        for (var n = 0; n < text.length; n++) {
          advance();
        }
        if (text.endsWith('n')) {
          kind = 'bigint';
          value = BigInt.parse(text.substring(0, text.length - 1));
        } else if (text.startsWith(RegExp(r'0[bBoO]'))) {
          value = int.parse(
            text.substring(2),
            radix: text[1].toLowerCase() == 'b' ? 2 : 8,
          );
        } else {
          value = num.parse(text);
        }
      } else if (RegExp(r'[a-zA-Z_$]').hasMatch(c)) {
        kind = 'identifier';
        while (i < source.length &&
            RegExp(r'[a-zA-Z0-9_$]').hasMatch(source[i])) {
          advance();
        }
      } else {
        String? op;
        for (final candidate in operators) {
          if (source.startsWith(candidate, i)) {
            op = candidate;
            break;
          }
        }
        for (var n = 0; n < (op?.length ?? 1); n++) {
          advance();
        }
      }
      tokens.add(
        Token(
          source.substring(start, i),
          kind,
          value,
          start,
          startLine,
          startColumn,
          line,
        ),
      );
    }
    tokens.add(Token('<eof>', 'eof', null, i, line, column, line));
  }

  Node parse() {
    final t = token;
    final body = <Node>[];
    while (token.kind != 'eof') {
      body.add(statement());
    }
    return node('Program', t, {'body': body});
  }

  void semicolon() {
    if (take(';') || at('}') || token.kind == 'eof') return;
    if (cursor > 0 && token.line > tokens[cursor - 1].endLine) return;
    fail('Expected semicolon');
  }

  Node block() {
    final t = expect('{');
    final body = <Node>[];
    while (!at('}')) {
      if (token.kind == 'eof') fail('Unterminated block');
      body.add(statement());
    }
    expect('}');
    return node('BlockStatement', t, {'body': body});
  }

  Node statement() {
    final t = token;
    if (at('{')) return block();
    if (take(';')) return node('EmptyStatement', t);
    if (at('var') || at('let') || at('const')) {
      final n = declaration();
      semicolon();
      return n;
    }
    if (take('function')) return function(t, true);
    if (take('return')) {
      final arg =
          at(';') || at('}') || token.kind == 'eof' || token.line > t.line
          ? null
          : expression();
      semicolon();
      return node('ReturnStatement', t, {'argument': arg});
    }
    if (take('if')) {
      expect('(');
      final test = expression();
      expect(')');
      final yes = statement();
      final no = take('else') ? statement() : null;
      return node('IfStatement', t, {
        'test': test,
        'consequent': yes,
        'alternate': no,
      });
    }
    if (take('for')) {
      expect('(');
      final init = at(';')
          ? null
          : (at('var') || at('let') || at('const')
                ? declaration()
                : expression(0, false));
      if (at('of') || at('in')) {
        final op = token.text;
        cursor++;
        final right = expression();
        expect(')');
        return node(op == 'of' ? 'ForOfStatement' : 'ForInStatement', t, {
          'left': init,
          'right': right,
          'body': statement(),
        });
      }
      expect(';');
      final test = at(';') ? null : expression();
      expect(';');
      final update = at(')') ? null : expression();
      expect(')');
      return node('ForStatement', t, {
        'init': init,
        'test': test,
        'update': update,
        'body': statement(),
      });
    }
    if (take('while')) {
      expect('(');
      final test = expression();
      expect(')');
      return node('WhileStatement', t, {'test': test, 'body': statement()});
    }
    if (take('do')) {
      final body = statement();
      expect('while');
      expect('(');
      final test = expression();
      expect(')');
      take(';');
      return node('DoWhileStatement', t, {'test': test, 'body': body});
    }
    if (take('break') || take('continue')) {
      semicolon();
      return node(
        t.text == 'break' ? 'BreakStatement' : 'ContinueStatement',
        t,
      );
    }
    final expr = expression();
    semicolon();
    return node('ExpressionStatement', t, {'expression': expr});
  }

  Node declaration() {
    final t = token;
    cursor++;
    final declarations = <Node>[];
    do {
      final id = identifier();
      final init = take('=') ? expression(2, false) : null;
      declarations.add(node('VariableDeclarator', t, {'id': id, 'init': init}));
    } while (take(','));
    return node('VariableDeclaration', t, {
      'kind': t.text,
      'declarations': declarations,
    });
  }

  Node identifier() {
    final t = token;
    if (t.kind != 'identifier') fail('Expected identifier');
    cursor++;
    return node('Identifier', t, {'name': t.text});
  }

  List<Node> parameters() {
    expect('(');
    final params = <Node>[];
    if (!at(')')) {
      do {
        if (at(')')) break;
        final t = token;
        if (take('...')) {
          params.add(node('RestElement', t, {'argument': identifier()}));
          break;
        }
        final id = identifier();
        params.add(
          take('=')
              ? node('AssignmentPattern', t, {
                  'left': id,
                  'right': expression(2),
                })
              : id,
        );
      } while (take(','));
    }
    expect(')');
    return params;
  }

  Node function(Token t, bool declaration) {
    final id = token.kind == 'identifier' ? identifier() : null;
    if (declaration && id == null) fail('Function declaration requires a name');
    final params = parameters();
    return node(declaration ? 'FunctionDeclaration' : 'FunctionExpression', t, {
      'id': id,
      'params': params,
      'body': block(),
    });
  }

  static const precedence = {
    ',': 1,
    '=': 2,
    '+=': 2,
    '-=': 2,
    '*=': 2,
    '/=': 2,
    '%=': 2,
    '**=': 2,
    '??': 4,
    '||': 4,
    '&&': 5,
    '==': 6,
    '!=': 6,
    '===': 6,
    '!==': 6,
    '<': 7,
    '>': 7,
    '<=': 7,
    '>=': 7,
    'in': 7,
    'instanceof': 7,
    '+': 8,
    '-': 8,
    '*': 9,
    '/': 9,
    '%': 9,
    '**': 10,
  };
  Node expression([int minimum = 0, bool allowIn = true]) {
    final t = token;
    Node left;
    if (token.kind == 'identifier' &&
        cursor + 1 < tokens.length &&
        tokens[cursor + 1].text == '=>') {
      final id = identifier();
      expect('=>');
      left = node('ArrowFunctionExpression', t, {
        'params': [id],
        'body': at('{') ? block() : expression(2),
      });
    } else if (at('(') && _arrowAhead()) {
      final params = parameters();
      expect('=>');
      left = node('ArrowFunctionExpression', t, {
        'params': params,
        'body': at('{') ? block() : expression(2),
      });
    } else if ([
      '!',
      '~',
      '+',
      '-',
      'typeof',
      'void',
      'delete',
      '++',
      '--',
    ].contains(token.text)) {
      cursor++;
      left = node(
        t.text == '++' || t.text == '--'
            ? 'UpdateExpression'
            : 'UnaryExpression',
        t,
        {'operator': t.text, 'argument': expression(11), 'prefix': true},
      );
    } else {
      left = primary();
    }
    while (true) {
      if (take('.') || take('?.')) {
        final optional = tokens[cursor - 1].text == '?.';
        final computed = take('[');
        final property = computed ? expression() : identifier();
        if (computed) expect(']');
        left = node(
          optional ? 'OptionalMemberExpression' : 'MemberExpression',
          t,
          {
            'object': left,
            'property': property,
            'computed': computed,
            'optional': optional,
          },
        );
        continue;
      }
      if (take('[')) {
        final property = expression();
        expect(']');
        left = node('MemberExpression', t, {
          'object': left,
          'property': property,
          'computed': true,
        });
        continue;
      }
      if (take('(')) {
        final args = <Node>[];
        if (!at(')')) {
          do {
            if (at(')')) break;
            args.add(argument());
          } while (take(','));
        }
        expect(')');
        left = node('CallExpression', t, {'callee': left, 'arguments': args});
        continue;
      }
      if ((at('++') || at('--')) && token.line == tokens[cursor - 1].endLine) {
        final op = token.text;
        cursor++;
        left = node('UpdateExpression', t, {
          'operator': op,
          'argument': left,
          'prefix': false,
        });
        continue;
      }
      if (at('?') && minimum <= 3) {
        cursor++;
        final yes = expression(2);
        expect(':');
        final no = expression(2);
        left = node('ConditionalExpression', t, {
          'test': left,
          'consequent': yes,
          'alternate': no,
        });
        continue;
      }
      final op = token.text;
      final p = precedence[op];
      if (p == null || p < minimum || (!allowIn && op == 'in')) break;
      cursor++;
      final right = expression(p == 2 || op == '**' ? p : p + 1, allowIn);
      if (op == ',') {
        left = node('SequenceExpression', t, {
          'expressions': [left, right],
        });
      } else {
        left = node(
          p == 2
              ? 'AssignmentExpression'
              : ['&&', '||', '??'].contains(op)
              ? 'LogicalExpression'
              : 'BinaryExpression',
          t,
          {'operator': op, 'left': left, 'right': right},
        );
      }
    }
    return left;
  }

  bool _arrowAhead() {
    var depth = 0;
    for (var i = cursor; i < tokens.length; i++) {
      if (tokens[i].text == '(') depth++;
      if (tokens[i].text == ')') {
        depth--;
        if (depth == 0)
          return i + 1 < tokens.length && tokens[i + 1].text == '=>';
      }
    }
    return false;
  }

  Node argument() {
    final t = token;
    if (take('...'))
      return node('SpreadElement', t, {'argument': expression(2)});
    return expression(2);
  }

  Node primary() {
    final t = token;
    if (take('(')) {
      final n = expression();
      expect(')');
      return n;
    }
    if (take('function')) return function(t, false);
    if (take('this')) return node('ThisExpression', t);
    if (take('true') || take('false'))
      return node('BooleanLiteral', t, {'value': t.text == 'true'});
    if (take('null')) return node('NullLiteral', t);
    if (t.kind == 'regexp') {
      cursor++;
      return node('RegExpLiteral', t, Map<String, dynamic>.from(t.value));
    }
    if (t.kind == 'number' ||
        t.kind == 'bigint' ||
        t.kind == 'string' ||
        t.kind == 'template') {
      cursor++;
      return node(
        {
          'number': 'NumericLiteral',
          'bigint': 'BigIntLiteral',
          'string': 'StringLiteral',
          'template': 'TemplateLiteral',
        }[t.kind]!,
        t,
        {'value': t.value},
      );
    }
    if (take('[')) {
      final elements = <Node?>[];
      while (!at(']')) {
        if (take(',')) {
          elements.add(null);
          continue;
        }
        elements.add(argument());
        if (!take(',')) break;
      }
      expect(']');
      return node('ArrayExpression', t, {'elements': elements});
    }
    if (take('{')) {
      final properties = <Node>[];
      while (!at('}')) {
        final p = token;
        if (take('...')) {
          properties.add(node('SpreadElement', p, {'argument': expression(2)}));
        } else {
          final computed = take('[');
          Node key;
          if (computed) {
            key = expression();
            expect(']');
          } else if (token.kind == 'string' || token.kind == 'number') {
            key = primary();
          } else {
            key = identifier();
          }
          Node value;
          if (take(':')) {
            value = expression(2);
          } else {
            value = key;
          }
          properties.add(
            node('ObjectProperty', p, {
              'key': key,
              'value': value,
              'computed': computed,
            }),
          );
        }
        if (!take(',')) break;
      }
      expect('}');
      return node('ObjectExpression', t, {'properties': properties});
    }
    if (t.kind == 'identifier') {
      if ([
        'new',
        'class',
        'throw',
        'switch',
        'try',
        'await',
        'yield',
      ].contains(t.text))
        fail('Unsupported syntax: ${t.text}');
      return identifier();
    }
    fail('Unexpected token: ${t.text}');
  }
}
