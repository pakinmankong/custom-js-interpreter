import 'dart:math' as math;
import 'errors.dart';

class JsUndefined {
  const JsUndefined._();
  @override
  String toString() => 'undefined';
}

class JsArrayHole extends JsUndefined {
  const JsArrayHole._() : super._();
}

const undefined = JsUndefined._();
const arrayHole = JsArrayHole._();
dynamic arrayValue(dynamic v) => identical(v, arrayHole) ? undefined : v;

class JsRegExp {
  final String pattern, flags;
  late final RegExp regex;
  int lastIndex = 0;
  JsRegExp(this.pattern, this.flags) {
    regex = RegExp(
      pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'),
    );
  }
  bool get global => flags.contains('g');
  bool get sticky => flags.contains('y');
  RegExpMatch? match(String input) {
    final start = global || sticky ? lastIndex : 0;
    if (start > input.length || start < 0) {
      if (global || sticky) lastIndex = 0;
      return null;
    }
    final matches = regex.allMatches(input, start);
    final result = matches.isEmpty ? null : matches.first;
    final matched = result != null && (!sticky || result.start == start)
        ? result
        : null;
    if (global || sticky) lastIndex = matched?.end ?? 0;
    return matched;
  }

  @override
  String toString() => '/$pattern/$flags';
}

bool isNullish(dynamic v) => v == null || v is JsUndefined;
bool truthy(dynamic v) =>
    !isNullish(v) &&
    v != false &&
    v != '' &&
    !(v is num && (v == 0 || v.isNaN)) &&
    !(v is BigInt && v == BigInt.zero);
String jsString(dynamic v) {
  if (v is JsUndefined) return 'undefined';
  if (v == null) return 'null';
  if (v is List) return v.map((e) => isNullish(e) ? '' : jsString(e)).join(',');
  if (v is Map) return '[object Object]';
  if (v is num) return jsNumberString(v);
  return v.toString();
}

String jsNumberString(num v) {
  if (v == 0) return '0';
  if (!v.isFinite) return v.toString();
  final text = v.toString();
  if (!text.contains('e'))
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  final parts = text.split('e'), exponent = int.parse(text.split('e')[1]);
  var mantissa = parts[0];
  if (v.abs() >= 1e21 || v.abs() < 1e-6) {
    if (mantissa.endsWith('.0'))
      mantissa = mantissa.substring(0, mantissa.length - 2);
    return '${mantissa}e${exponent >= 0 ? '+' : ''}$exponent';
  }
  final negative = mantissa.startsWith('-');
  if (negative) mantissa = mantissa.substring(1);
  final decimal =
      (mantissa.contains('.') ? mantissa.indexOf('.') : mantissa.length) +
      exponent;
  final digits = mantissa.replaceAll('.', '');
  final expanded = decimal <= 0
      ? '0.${'0' * -decimal}$digits'
      : decimal >= digits.length
      ? digits + '0' * (decimal - digits.length)
      : '${digits.substring(0, decimal)}.${digits.substring(decimal)}';
  return '${negative ? '-' : ''}$expanded';
}

num jsNumber(dynamic v) {
  if (v == null) return 0;
  if (v is JsUndefined) return double.nan;
  if (v is num) return v;
  if (v is BigInt) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  final text = jsString(v).trim();
  if (text.isEmpty) return 0;
  if (RegExp(r'^0[bBoOxX][0-9a-fA-F]+$').hasMatch(text)) {
    final radix = text[1].toLowerCase() == 'b'
        ? 2
        : text[1].toLowerCase() == 'o'
        ? 8
        : 16;
    return BigInt.tryParse(text.substring(2), radix: radix)?.toDouble() ??
        double.nan;
  }
  if (!RegExp(
    r'^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$',
  ).hasMatch(text))
    return double.nan;
  return double.tryParse(text) ?? double.nan;
}

int toInt32(dynamic value) {
  final n = jsNumber(value);
  if (!n.isFinite || n == 0) return 0;
  final unsigned = (n.truncateToDouble() % 4294967296).toInt();
  return unsigned >= 2147483648 ? unsigned - 4294967296 : unsigned;
}

List<String> jsObjectKeys(Map value) {
  final keys = value.keys.map(jsString).toList();
  final indices = keys
      .where(
        (k) =>
            RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(k) &&
            (num.tryParse(k) ?? double.infinity) < 4294967295,
      )
      .toList();
  indices.sort((a, b) => num.parse(a).compareTo(num.parse(b)));
  return [...indices, ...keys.where((k) => !indices.contains(k))];
}

bool strictEqual(dynamic a, dynamic b) {
  if (a is JsUndefined || b is JsUndefined)
    return a is JsUndefined && b is JsUndefined;
  if (a is num && b is num) return a == b;
  if (a is List ||
      a is Map ||
      a is JsCallable ||
      b is List ||
      b is Map ||
      b is JsCallable)
    return identical(a, b);
  return a.runtimeType == b.runtimeType && a == b;
}

bool looseEqual(dynamic a, dynamic b) {
  if (isNullish(a) || isNullish(b)) return isNullish(a) && isNullish(b);
  if (strictEqual(a, b)) return true;
  if (a is bool) return looseEqual(jsNumber(a), b);
  if (b is bool) return looseEqual(a, jsNumber(b));
  if (a is List || a is Map)
    return b is List || b is Map ? identical(a, b) : looseEqual(jsString(a), b);
  if (b is List || b is Map) return looseEqual(a, jsString(b));
  if (a is BigInt || b is BigInt) {
    final big = a is BigInt ? a : b as BigInt, other = a is BigInt ? b : a;
    if (other is String) return BigInt.tryParse(other.trim()) == big;
    if (other is num && other.isFinite && other == other.truncateToDouble())
      return BigInt.from(other) == big;
    return false;
  }
  if ((a is num && b is String) || (a is String && b is num))
    return jsNumber(a) == jsNumber(b);
  return false;
}

String jsTypeof(dynamic v) {
  if (v is JsUndefined) return 'undefined';
  if (v is JsCallable || v is Function) return 'function';
  if (v is num) return 'number';
  if (v is BigInt) return 'bigint';
  if (v is String) return 'string';
  if (v is bool) return 'boolean';
  return 'object';
}

abstract class JsCallable {
  dynamic invoke(List<dynamic> args, dynamic thisValue);
}

typedef NativeBody = dynamic Function(List<dynamic> args, dynamic thisValue);

class NativeFunction implements JsCallable {
  final NativeBody body;
  final NativeBody? asyncBody;
  final String? arrayMethod;
  NativeFunction(this.body, {this.asyncBody, this.arrayMethod});
  @override
  dynamic invoke(List<dynamic> args, dynamic thisValue) =>
      body(args, thisValue);
}

typedef CallFunction =
    dynamic Function(dynamic fn, List<dynamic> args, [dynamic thisValue]);

class JsRuntime {
  final CallFunction call;
  JsRuntime(this.call);
  final Expando<Map<String, dynamic>> _properties = Expando();
  int? _arrayIndex(String name) {
    if (!RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(name)) return null;
    final i = int.tryParse(name);
    return i != null && i < 4294967295 ? i : null;
  }

  bool hasProperty(dynamic object, dynamic key) {
    if (object is! Map &&
        object is! List &&
        object is! JsCallable &&
        object is! JsRegExp)
      throw JsError("Cannot use 'in' operator on a non-object");
    final name = jsString(key);
    if (object is Map) return object.containsKey(name) || name == 'toString';
    if (object is List) {
      final index = _arrayIndex(name);
      if (index != null)
        return index < object.length && !identical(object[index], arrayHole);
      return name == 'length' ||
          (_properties[object]?.containsKey(name) ?? false) ||
          !identical(_arrayMethod(object, name), undefined);
    }
    return !identical(property(object, key), undefined);
  }

  dynamic property(dynamic object, dynamic key) {
    if (isNullish(object))
      throw JsError('Cannot read property of null or undefined');
    final name = jsString(key);
    if (object is Map)
      return object.containsKey(name) ? object[name] : undefined;
    if (object is List) {
      if (name == 'length') return object.length;
      final index = _arrayIndex(name);
      if (index != null)
        return index >= 0 && index < object.length
            ? arrayValue(object[index])
            : undefined;
      if (_properties[object]?.containsKey(name) ?? false)
        return _properties[object]![name];
      return _arrayMethod(object, name);
    }
    if (object is String) {
      if (name == 'length') return object.length;
      final index = _arrayIndex(name);
      if (index != null)
        return index >= 0 && index < object.length
            ? arrayValue(object[index])
            : undefined;
      return _stringMethod(object, name);
    }
    if (object is JsRegExp) {
      if (name == 'test')
        return NativeFunction(
          (args, t) =>
              object.match(jsString(args.isEmpty ? undefined : args[0])) !=
              null,
        );
      if (name == 'source') return object.pattern;
      if (name == 'flags') return object.flags;
      if (name == 'global') return object.global;
      if (name == 'lastIndex') return object.lastIndex;
      if (name == 'exec')
        return NativeFunction((args, t) {
          final input = jsString(args.isEmpty ? undefined : args[0]);
          final match = object.match(input);
          if (match == null) return null;
          final result = <dynamic>[
            for (var i = 0; i <= match.groupCount; i++)
              match.group(i) ?? undefined,
          ];
          _properties[result] = {'index': match.start, 'input': input};
          return result;
        });
    }
    if (name == 'toString') return NativeFunction((a, t) => jsString(object));
    if (object is num && name == 'toFixed')
      return NativeFunction(
        (a, t) =>
            object.toStringAsFixed(a.isEmpty ? 0 : jsNumber(a[0]).toInt()),
      );
    return undefined;
  }

  dynamic setProperty(dynamic object, dynamic key, dynamic value) {
    final name = jsString(key);
    if (object is Map) return object[name] = value;
    if (object is JsRegExp && name == 'lastIndex') {
      object.lastIndex = jsNumber(value).toInt();
      return value;
    }
    if (object is List) {
      if (name == 'length') {
        final n = jsNumber(value);
        if (!n.isFinite || n < 0 || n != n.truncate())
          throw JsError('Invalid array length');
        if (n < object.length) object.removeRange(n.toInt(), object.length);
        while (object.length < n) {
          object.add(arrayHole);
        }
        return value;
      }
      final index = _arrayIndex(name);
      if (index == null) {
        (_properties[object] ??= {})[name] = value;
        return value;
      }
      while (object.length <= index) {
        object.add(arrayHole);
      }
      object[index] = value;
      return value;
    }
    throw JsError('Cannot assign property');
  }

  bool deleteProperty(dynamic object, dynamic key) {
    if (object is Map) {
      object.remove(jsString(key));
      return true;
    }
    if (object is List) {
      if (jsString(key) == 'length')
        throw JsError("Cannot delete property 'length' of [object Array]");
      final index = _arrayIndex(jsString(key));
      if (index != null && index >= 0 && index < object.length)
        object[index] = arrayHole;
      if (index == null) _properties[object]?.remove(jsString(key));
      return true;
    }
    return true;
  }

  List<dynamic> iterable(dynamic value) {
    if (value is List) return value.map(arrayValue).toList();
    if (value is String) return value.runes.map(String.fromCharCode).toList();
    throw JsError('Value is not iterable');
  }

  List<String> keys(dynamic value) {
    if (isNullish(value)) return [];
    if (value is Map) return jsObjectKeys(value);
    if (value is List)
      return [
        for (var i = 0; i < value.length; i++)
          if (!identical(value[i], arrayHole)) '$i',
        ...?_properties[value]?.keys,
      ];
    if (value is String) return List.generate(value.length, (i) => '$i');
    return [];
  }

  int _index(dynamic value, int length) {
    final n = jsNumber(value);
    final i = n.isNaN
        ? 0
        : n == double.infinity
        ? length
        : n == double.negativeInfinity
        ? -length
        : n.toInt();
    return i < 0 ? math.max(length + i, 0) : math.min(i, length);
  }

  dynamic _arrayMethod(List<dynamic> list, String name) {
    const supported = {
      'push',
      'pop',
      'shift',
      'unshift',
      'splice',
      'slice',
      'map',
      'filter',
      'reduce',
      'reduceRight',
      'forEach',
      'sort',
      'reverse',
      'join',
      'concat',
      'includes',
      'indexOf',
      'find',
      'findIndex',
      'some',
      'every',
    };
    if (!supported.contains(name)) return undefined;
    return NativeFunction((args, receiver) {
      switch (name) {
        case 'push':
          list.addAll(args);
          return list.length;
        case 'pop':
          return list.isEmpty ? undefined : arrayValue(list.removeLast());
        case 'shift':
          return list.isEmpty ? undefined : arrayValue(list.removeAt(0));
        case 'unshift':
          list.insertAll(0, args);
          return list.length;
        case 'splice':
          if (args.isEmpty) return <dynamic>[];
          final start = _index(args[0], list.length);
          final count = args.length < 2
              ? list.length - start
              : _index(args[1], list.length - start);
          // Negative deleteCount means zero, rather than indexing from the end.
          final deleteCount = args.length > 1 && jsNumber(args[1]) < 0
              ? 0
              : count;
          final removed = list.sublist(start, start + deleteCount);
          list.replaceRange(start, start + deleteCount, args.skip(2));
          return removed;
        case 'slice':
          final start = args.isEmpty ? 0 : _index(args[0], list.length);
          final end = args.length < 2 || identical(args[1], undefined)
              ? list.length
              : _index(args[1], list.length);
          return list.sublist(start, math.max(start, end));
        case 'reverse':
          final reversed = list.reversed.toList();
          list.setAll(0, reversed);
          return list;
        case 'join':
          return list
              .map((v) => isNullish(v) ? '' : jsString(v))
              .join(
                args.isEmpty || identical(args[0], undefined)
                    ? ','
                    : jsString(args[0]),
              );
        case 'concat':
          return <dynamic>[
            ...list,
            for (final arg in args) ...arg is List ? arg : [arg],
          ];
        case 'includes':
        case 'indexOf':
          final value = args.isEmpty ? undefined : args[0];
          final start = args.length > 1 ? _index(args[1], list.length) : 0;
          for (var i = start; i < list.length; i++) {
            if (name == 'indexOf' && identical(list[i], arrayHole)) continue;
            if (strictEqual(arrayValue(list[i]), value) ||
                (name == 'includes' &&
                    list[i] is num &&
                    value is num &&
                    (list[i] as num).isNaN &&
                    value.isNaN))
              return name == 'includes' ? true : i;
          }
          return name == 'includes' ? false : -1;
        case 'sort':
          final comparator = args.isEmpty ? undefined : args[0];
          list.sort((a, b) {
            if (identical(a, undefined)) return identical(b, undefined) ? 0 : 1;
            if (identical(b, undefined)) return -1;
            if (identical(comparator, undefined))
              return jsString(a).compareTo(jsString(b));
            final result = jsNumber(call(comparator, [a, b], undefined));
            return result.isNaN || result == 0
                ? 0
                : result < 0
                ? -1
                : 1;
          });
          return list;
        default:
          if (args.isEmpty || !(args[0] is JsCallable || args[0] is Function))
            throw JsError('Callback is not a function');
          final callback = args[0];
          final thisArg = args.length > 1 ? args[1] : undefined;
          final length = list.length;
          final results = name == 'map'
              ? List<dynamic>.filled(length, arrayHole)
              : <dynamic>[];
          dynamic accumulator = args.length > 1 ? args[1] : undefined;
          final reduce = name == 'reduce' || name == 'reduceRight';
          final step = name == 'reduceRight' ? -1 : 1;
          var start = step > 0 ? 0 : length - 1;
          if (reduce && args.length < 2) {
            while (start >= 0 && start < length && identical(list[start], arrayHole)) {
              start += step;
            }
            if (start < 0 || start >= length)
              throw JsError('Reduce of empty array with no initial value');
            accumulator = list[start];
            start += step;
          }
          for (var i = start; i >= 0 && i < length; i += step) {
            if (i >= list.length) continue;
            if (identical(list[i], arrayHole) &&
                name != 'find' &&
                name != 'findIndex')
              continue;
            final value = arrayValue(list[i]);
            final result = reduce
                ? call(callback, [accumulator, value, i, list], undefined)
                : call(callback, [value, i, list], thisArg);
            switch (name) {
              case 'map':
                results[i] = result;
              case 'filter':
                if (truthy(result)) results.add(value);
              case 'reduce':
              case 'reduceRight':
                accumulator = result;
              case 'find':
                if (truthy(result)) return value;
              case 'findIndex':
                if (truthy(result)) return i;
              case 'some':
                if (truthy(result)) return true;
              case 'every':
                if (!truthy(result)) return false;
            }
          }
          return switch (name) {
            'map' || 'filter' => results,
            'reduce' || 'reduceRight' => accumulator,
            'findIndex' => -1,
            'some' => false,
            'every' => true,
            _ => undefined,
          };
      }
    }, arrayMethod: name);
  }

  String _replace(String input, dynamic search, dynamic replacement) {
    final matches = <({int start, int end, List<dynamic> groups})>[];
    if (search is JsRegExp) {
      if (search.global) search.lastIndex = 0;
      final start = search.sticky ? search.lastIndex : 0;
      if (start >= 0 && start <= input.length) {
        for (final match in search.regex.allMatches(input, start)) {
          if (search.sticky &&
              match.start != (matches.isEmpty ? start : matches.last.end))
            break;
          matches.add((
            start: match.start,
            end: match.end,
            groups: [
              for (var i = 0; i <= match.groupCount; i++)
                match.group(i) ?? undefined,
            ],
          ));
          if (!search.global) break;
        }
      }
      if (search.global)
        search.lastIndex = 0;
      else if (search.sticky)
        search.lastIndex = matches.isEmpty ? 0 : matches.last.end;
    } else {
      final text = jsString(search), start = input.indexOf(jsString(search));
      if (start >= 0)
        matches.add((start: start, end: start + text.length, groups: [text]));
    }
    final result = StringBuffer();
    var last = 0;
    for (final match in matches) {
      result.write(input.substring(last, match.start));
      if (replacement is JsCallable || replacement is Function) {
        result.write(
          jsString(
            call(replacement, [...match.groups, match.start, input], undefined),
          ),
        );
      } else {
        final text = jsString(replacement);
        result.write(
          text.replaceAllMapped(RegExp(r'''\$(\$|&|`|'|[0-9]{1,2})'''), (
            token,
          ) {
            final key = token[1]!;
            if (key == r'$') return r'$';
            if (key == '&') return jsString(match.groups[0]);
            if (key == '`') return input.substring(0, match.start);
            if (key == "'") return input.substring(match.end);
            final index = int.parse(key);
            if (index > 0 && index < match.groups.length)
              return isNullish(match.groups[index])
                  ? ''
                  : jsString(match.groups[index]);
            if (key.length == 2 &&
                index >= 10 &&
                index ~/ 10 < match.groups.length) {
              final group = match.groups[index ~/ 10];
              return '${isNullish(group) ? '' : jsString(group)}${key[1]}';
            }
            return token[0]!;
          }),
        );
      }
      last = match.end;
    }
    result.write(input.substring(last));
    return result.toString();
  }

  Future<String> replaceAsync(
    String input,
    dynamic search,
    dynamic replacement,
    CallFunction asyncCall,
  ) async {
    final matches = <({int start, int end, List<dynamic> groups})>[];
    if (search is JsRegExp) {
      if (search.global) search.lastIndex = 0;
      final start = search.sticky ? search.lastIndex : 0;
      if (start >= 0 && start <= input.length) {
        for (final match in search.regex.allMatches(input, start)) {
          if (search.sticky &&
              match.start != (matches.isEmpty ? start : matches.last.end))
            break;
          matches.add((
            start: match.start,
            end: match.end,
            groups: [
              for (var i = 0; i <= match.groupCount; i++)
                match.group(i) ?? undefined,
            ],
          ));
          if (!search.global) break;
        }
      }
      if (search.global)
        search.lastIndex = 0;
      else if (search.sticky)
        search.lastIndex = matches.isEmpty ? 0 : matches.last.end;
    } else {
      final text = jsString(search), start = input.indexOf(jsString(search));
      if (start >= 0)
        matches.add((start: start, end: start + text.length, groups: [text]));
    }
    final result = StringBuffer();
    var last = 0;
    for (final match in matches) {
      result.write(input.substring(last, match.start));
      if (replacement is JsCallable || replacement is Function) {
        result.write(
          jsString(
            await asyncCall(replacement, [
              ...match.groups,
              match.start,
              input,
            ], undefined),
          ),
        );
      } else {
        final text = jsString(replacement);
        result.write(
          text.replaceAllMapped(RegExp(r'''\$(\$|&|`|'|[0-9]{1,2})'''), (
            token,
          ) {
            final key = token[1]!;
            if (key == r'$') return r'$';
            if (key == '&') return jsString(match.groups[0]);
            if (key == '`') return input.substring(0, match.start);
            if (key == "'") return input.substring(match.end);
            final index = int.parse(key);
            if (index > 0 && index < match.groups.length)
              return isNullish(match.groups[index])
                  ? ''
                  : jsString(match.groups[index]);
            if (key.length == 2 &&
                index >= 10 &&
                index ~/ 10 < match.groups.length) {
              final group = match.groups[index ~/ 10];
              return '${isNullish(group) ? '' : jsString(group)}${key[1]}';
            }
            return token[0]!;
          }),
        );
      }
      last = match.end;
    }
    result.write(input.substring(last));
    return result.toString();
  }

  dynamic _stringMethod(String value, String name) {
    const supported = {
      'trim',
      'toLowerCase',
      'toUpperCase',
      'split',
      'includes',
      'startsWith',
      'endsWith',
      'indexOf',
      'slice',
      'substring',
      'repeat',
      'charAt',
      'replace',
    };
    if (!supported.contains(name)) return undefined;
    return NativeFunction((args, t) {
      final first = args.isEmpty ? undefined : args[0];
      int position(dynamic v, [int? fallback]) {
        if (identical(v, undefined)) return fallback ?? 0;
        final n = jsNumber(v);
        return n.isNaN
            ? 0
            : n == double.infinity
            ? value.length
            : n == double.negativeInfinity
            ? 0
            : n.toInt().clamp(0, value.length);
      }

      final second = args.length > 1 ? args[1] : undefined;
      switch (name) {
        case 'trim':
          return value.trim();
        case 'toLowerCase':
          return value.toLowerCase();
        case 'toUpperCase':
          return value.toUpperCase();
        case 'split':
          final limit = identical(second, undefined)
              ? 4294967295
              : toInt32(second).toUnsigned(32);
          if (limit == 0) return <dynamic>[];
          if (identical(first, undefined)) return <dynamic>[value];
          if (first is! JsRegExp)
            return value.split(jsString(first)).take(limit).toList();
          final result = <dynamic>[];
          var last = 0;
          if (value.isEmpty) return first.regex.hasMatch(value) ? result : [''];
          for (final match in first.regex.allMatches(value)) {
            if (match.start == match.end &&
                (match.start == last || match.start == value.length))
              continue;
            result.add(value.substring(last, match.start));
            for (var i = 1; i <= match.groupCount; i++) {
              result.add(match.group(i) ?? undefined);
            }
            last = match.end;
            if (result.length >= limit) return result.take(limit).toList();
          }
          result.add(value.substring(last));
          return result.take(limit).toList();
        case 'includes':
          return value.indexOf(jsString(first), position(second)) >= 0;
        case 'startsWith':
          return value.startsWith(jsString(first), position(second));
        case 'endsWith':
          return value
              .substring(0, position(second, value.length))
              .endsWith(jsString(first));
        case 'indexOf':
          return value.indexOf(jsString(first), position(second));
        case 'slice':
          final start = args.isEmpty ? 0 : _index(first, value.length);
          final end = args.length < 2
              ? value.length
              : _index(args[1], value.length);
          return value.substring(start, math.max(start, end));
        case 'substring':
          final start = args.isEmpty
              ? 0
              : jsNumber(first).toInt().clamp(0, value.length);
          final end = args.length < 2
              ? value.length
              : jsNumber(args[1]).toInt().clamp(0, value.length);
          return value.substring(math.min(start, end), math.max(start, end));
        case 'repeat':
          return value * jsNumber(first).toInt();
        case 'charAt':
          final index = args.isEmpty ? 0 : jsNumber(first).toInt();
          return index < 0 || index >= value.length ? '' : value[index];
        case 'replace':
          return _replace(value, first, second);
      }
    });
  }
}
