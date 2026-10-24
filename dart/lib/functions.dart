import 'dart:async';
import 'dart:math' as math;
import 'base_functions.dart';
import 'env.dart';
import 'errors.dart';
import 'runtime.dart';
import 'statistics.dart';
import 'interpreter_service.dart' show InterpreterFunction;

/// Providers must return already loaded data synchronously; Futures are rejected.
class FunctionServices {
  final dynamic Function(dynamic standardId)? getStandardErrors;
  final dynamic Function(dynamic unitId)? getUnitById;
  final dynamic Function(dynamic name)? getUnitByName;
  final dynamic Function(dynamic fromId, dynamic toId, num value)? convertUnit;
  const FunctionServices({
    this.getStandardErrors,
    this.getUnitById,
    this.getUnitByName,
    this.convertUnit,
  });
}

dynamic _arg(List<dynamic> args, int index, [dynamic fallback = undefined]) =>
    index < args.length && !identical(args[index], undefined)
    ? args[index]
    : fallback;
dynamic _required(dynamic value, String name, String parameter) {
  if (identical(value, undefined))
    throw JsError('$name() <$parameter> is required');
  return value;
}

num _numeric(dynamic value, String name, [String parameter = 'number']) {
  _required(value, name, parameter);
  final n = jsNumber(value);
  if (!n.isFinite)
    throw JsError('$name() <$parameter> must be a finite number');
  return n;
}

int _integer(dynamic value, String name, String parameter) {
  final n = _numeric(value, name, parameter);
  if (n != n.truncateToDouble())
    throw JsError('$name() <$parameter> must be an integer');
  return n.toInt();
}

List<dynamic> _array(dynamic value, String name) {
  _required(value, name, 'array');
  if (value is! List) throw JsError('$name() <array> must be an array');
  return value;
}

dynamic _sync(dynamic value, String name) {
  if (value is Future)
    throw JsError(
      '$name() requires synchronous/preloaded data; Future is not supported',
    );
  return value;
}

dynamic _normalize(dynamic value) =>
    jsNumber(value).isNaN ? value : jsNumber(value);
dynamic _field(dynamic value, dynamic key) {
  if (value is Map)
    return value.containsKey(jsString(key)) ? value[jsString(key)] : undefined;
  if (value is List) {
    final i = int.tryParse(jsString(key));
    if (i != null && i >= 0 && i < value.length) return value[i];
  }
  return undefined;
}

List<dynamic> _values(dynamic value) => value is Map
    ? value.values.toList()
    : value is List
    ? value
    : [];

int matchValue(dynamic value, List<dynamic> data, [dynamic matchType = 1]) {
  if (![0, 1, -1].contains(matchType))
    throw JsError('MATCH() matchType must be -1, 0 or 1');
  final lookup = _normalize(value);
  var found = -1;
  for (var i = 0; i < data.length; i++) {
    final item = _normalize(data[i]);
    if (matchType == 0) {
      if (strictEqual(item, lookup)) return i;
    } else {
      final compare = item is String && lookup is String
          ? (matchType == 1
                ? item.compareTo(lookup) <= 0
                : item.compareTo(lookup) >= 0)
          : (matchType == 1
                ? jsNumber(item) <= jsNumber(lookup)
                : jsNumber(item) >= jsNumber(lookup));
      if (compare) found = i;
    }
  }
  return found;
}

List<List<double>> _matrix(dynamic value, String name) {
  final rows = _array(value, name);
  if (rows.isEmpty || rows[0] is! List || (rows[0] as List).isEmpty)
    throw JsError('$name() expects a nonempty rectangular matrix');
  final width = (rows[0] as List).length;
  return rows.map((row) {
    if (row is! List || row.length != width)
      throw JsError('$name() expects a rectangular matrix');
    return row.map((v) => _numeric(v, name).toDouble()).toList();
  }).toList();
}

List<List<double>> _inverse(dynamic value) {
  final a = _matrix(value, 'MINVERSE'), n = (value as List).length;
  if (a[0].length != n) throw JsError('MINVERSE() expects a square matrix');
  final work = List.generate(
    n,
    (i) => <double>[...a[i], ...List.generate(n, (j) => i == j ? 1.0 : 0.0)],
  );
  for (var column = 0; column < n; column++) {
    var pivot = column;
    for (var i = column + 1; i < n; i++) {
      if (work[i][column].abs() > work[pivot][column].abs()) pivot = i;
    }
    if (work[pivot][column] == 0)
      throw JsError('MINVERSE() matrix is singular');
    final row = work[column];
    work[column] = work[pivot];
    work[pivot] = row;
    final divisor = work[column][column];
    for (var j = 0; j < n * 2; j++) {
      work[column][j] /= divisor;
    }
    for (var i = 0; i < n; i++) {
      if (i == column) continue;
      final factor = work[i][column];
      for (var j = 0; j < n * 2; j++) {
        work[i][j] -= factor * work[column][j];
      }
    }
  }
  return work.map((row) => row.sublist(n)).toList();
}

/// Register the same 51 formula functions plus print as lib/functions.ts.
Map<String, dynamic> createFunctions({
  Env Function()? getEnv,
  FunctionServices? services,
  void Function(List<dynamic>)? output,
}) {
  final base = createBaseFunctions(output: output);
  final random = math.Random();
  dynamic envValue(String name, [dynamic fallback = undefined]) {
    final env = getEnv?.call();
    return env != null && env.has(name) ? env.get(name) : fallback;
  }

  int currentRow(dynamic level) {
    final i = _integer(level, 'GET_CURRENT_ROW_INDEX', 'level');
    final rows = envValue('CURRENT_ROW');
    if (rows is! List ||
        i < 0 ||
        i >= rows.length ||
        identical(rows[i], undefined))
      throw JsError('CURRENT_ROW[$i] is required');
    return _integer(rows[i], 'GET_CURRENT_ROW_INDEX', 'row index');
  }

  List<dynamic> standards(dynamic id) {
    _required(id, 'FIND_STD_ERROR', 'standard_id');
    final provider = services?.getStandardErrors;
    if (provider == null)
      throw JsError(
        'Standard service is not configured: provide services.getStandardErrors',
      );
    final records = List<dynamic>.of(
      _array(_sync(provider(id), 'FIND_STD_ERROR'), 'FIND_STD_ERROR'),
    );
    records.sort(
      (a, b) =>
          jsNumber(_field(a, 'value')).compareTo(jsNumber(_field(b, 'value'))),
    );
    return records;
  }

  dynamic normalizeUnit(dynamic unit) {
    if (!truthy(unit)) return null;
    dynamic coalesce(dynamic a, dynamic b) => isNullish(a) ? b : a;
    return {
      'ID': coalesce(_field(unit, 'ID'), _field(unit, 'unit_id')),
      'SYMBOL': coalesce(
        _field(unit, 'SYMBOL'),
        _field(unit, 'unit_short_name_en'),
      ),
      'NAME': coalesce(_field(unit, 'NAME'), _field(unit, 'unit_name_en')),
    };
  }

  dynamic invokeBase(String name, List<dynamic> args) =>
      (base[name] as JsCallable).invoke(args, undefined);
  num directed(List<dynamic> args, bool up) {
    final name = up ? 'ROUNDUP' : 'ROUNDDOWN';
    final n = _numeric(_arg(args, 0), name),
        d = _integer(_arg(args, 1, 0), name, 'digits');
    final factor = math.pow(10, d), scaled = n * math.pow(10, d);
    if (!factor.isFinite || factor == 0 || !scaled.isFinite)
      throw JsError('Rounding digits are out of range');
    return (up
            ? (n >= 0 ? scaled.ceil() : scaled.floor())
            : scaled.truncate()) /
        factor;
  }

  return {
    ...base,
    'SUCCESS': NativeFunction(
      (a, t) => {
        'type': 'success',
        'value': _arg(a, 0, null),
        'message': _arg(a, 1),
      },
    ),
    'ERROR': NativeFunction(
      (a, t) => {
        'type': 'error',
        'message': _arg(a, 0, ''),
        'data': _arg(a, 1, null),
      },
    ),
    'FIRST': NativeFunction((a, t) {
      final items = _array(_arg(a, 0), 'FIRST');
      return items.isEmpty ? null : items.first;
    }),
    'LAST': NativeFunction((a, t) {
      final items = _array(_arg(a, 0), 'LAST');
      return items.isEmpty
          ? null
          : truthy(_arg(a, 1, false))
          ? items.length - 1
          : items.last;
    }),
    'COUNT': NativeFunction((a, t) => _array(_arg(a, 0), 'COUNT').length),
    'SORTING': NativeFunction((a, t) {
      final items = _array(_arg(a, 0), 'SORTING');
      final asc = _arg(a, 1, 'asc') == 'asc';
      items.sort((x, y) {
        final n = jsNumber(x) - jsNumber(y);
        return n.isNaN || n == 0 ? 0 : (asc ? n.sign : -n.sign).toInt();
      });
      return items;
    }),
    'IS_INFINITY': NativeFunction((a, t) {
      final n = jsNumber(_required(_arg(a, 0), 'IS_INFINITY', 'number'));
      if (n.isNaN) throw JsError('IS_INFINITY() <number> must be a number');
      return n.isInfinite;
    }),
    'FIND_INDEX': NativeFunction((a, t) {
      final value = _normalize(
        _required(_arg(a, 1), 'FIND_INDEX', 'lookup_value'),
      );
      final items = _array(_arg(a, 0), 'FIND_INDEX');
      final last = truthy(_arg(a, 2, false));
      var found = -1;
      for (var i = 0; i < items.length; i++) {
        if (strictEqual(_normalize(items[i]), value)) {
          found = i;
          if (!last) break;
        }
      }
      return found < 0 ? null : found;
    }),
    'MAP': NativeFunction((a, t) {
      final data = _arg(a, 0),
          key = _required(_arg(a, 1), 'MAP', 'map_key'),
          filters = _arg(a, 2);
      if (data is! Map && data is! List)
        throw JsError('MAP() expects an array or object');
      if (!isNullish(filters)) _array(filters, 'MAP');
      final keys = data is Map
          ? jsObjectKeys(data)
          : List.generate((data as List).length, (i) => '$i');
      final result = <dynamic>[];
      for (final k in keys) {
        final index = _normalize(k);
        final included =
            filters is List && filters.any((v) => strictEqual(v, index));
        if (filters is List &&
            (identical(_arg(a, 3, false), true) ? included : !included))
          continue;
        final item = _field(data, k);
        result.add(truthy(key) ? _normalize(_field(item, key)) : item);
      }
      return result;
    }),
    'SUM': NativeFunction((a, t) {
      if (a.length == 2 && a[1] is String && (a[0] is List || a[0] is Map))
        return _values(a[0]).fold<num>(0, (sum, item) {
          final v = _field(item, a[1]);
          return sum + jsNumber(isNullish(v) ? 0 : v);
        });
      if (a.length == 1 && a[0] is Map) return 0;
      return invokeBase('SUM', a);
    }),
    'AVERAGE': NativeFunction(
      (a, t) => flattenValues(a).isEmpty ? 0 : invokeBase('AVERAGE', a),
    ),
    'STDEV': NativeFunction((a, t) {
      final n = flattenValues(a).length;
      return n == 0
          ? 0
          : n == 1
          ? double.nan
          : invokeBase('STDEV', a);
    }),
    'FIXED': NativeFunction(
      (a, t) => invokeBase('FIXED', [
        _arg(a, 0),
        _integer(_arg(a, 1, 2), 'FIXED', 'digits'),
      ]),
    ),
    'EMPTY': NativeFunction((a, t) {
      final v = _arg(a, 0);
      return isNullish(v) ||
          (v is num && v.isNaN) ||
          (v is List && v.isEmpty) ||
          (v is String && v.trim().isEmpty);
    }),
    'STR': NativeFunction((a, t) => jsString(_arg(a, 0))),
    'NUM': NativeFunction((a, t) => jsNumber(_arg(a, 0))),
    'ROW': NativeFunction((a, t) {
      final items = _array(_arg(a, 0), 'ROW'), manual = _arg(a, 1, null);
      final i = manual == null || identical(manual, false)
          ? currentRow(_arg(a, 2, 0))
          : _integer(manual, 'ROW', 'row index');
      return i < 0 || i >= items.length ? undefined : items[i];
    }),
    'GET_CURRENT_ROW_INDEX': NativeFunction(
      (a, t) => currentRow(_arg(a, 0, 0)),
    ),
    'MATCH': NativeFunction(
      (a, t) => matchValue(
        _required(_arg(a, 0), 'MATCH', 'lookup_value'),
        _array(_arg(a, 1), 'MATCH'),
        _arg(a, 2, 1),
      ),
    ),
    'INDEX': NativeFunction((a, t) {
      final rows = _array(_arg(a, 0), 'INDEX');
      final r = _integer(_arg(a, 1), 'INDEX', 'row index'),
          c = _integer(_arg(a, 2), 'INDEX', 'column index');
      if (r < 0 || c < 0 || r >= rows.length) return null;
      final v = _field(rows[r], c);
      return isNullish(v) ? null : v;
    }),
    'ISNULL': NativeFunction((a, t) => _arg(a, 0) == null),
    'FORMAT_EXPO': NativeFunction((a, t) {
      final n = _numeric(_arg(a, 0), 'FORMAT_EXPO'), digits = _arg(a, 1);
      final text = identical(digits, undefined)
          ? n.toStringAsExponential()
          : n.toStringAsExponential(
              _integer(digits, 'FORMAT_EXPO', 'fractionDigits'),
            );
      return text.replaceFirstMapped(
        RegExp(r'e([+-])0+(\d+)'),
        (m) => 'e${m[1]}${m[2]}',
      );
    }),
    'ROUNDUP': NativeFunction((a, t) => directed(a, true)),
    'ROUNDDOWN': NativeFunction((a, t) => directed(a, false)),
    'INT': NativeFunction((a, t) => _numeric(_arg(a, 0), 'INT').floor()),
    'MMULT': NativeFunction((a, t) {
      final x = _matrix(_arg(a, 0), 'MMULT'), y = _matrix(_arg(a, 1), 'MMULT');
      if (x[0].length != y.length)
        throw JsError(
          'Matrix dimensions are not compatible for multiplication.',
        );
      return x
          .map(
            (row) => List.generate(y[0].length, (c) {
              var sum = 0.0;
              for (var k = 0; k < row.length; k++) {
                sum += row[k] * y[k][c];
              }
              return sum;
            }),
          )
          .toList();
    }),
    'MINVERSE': NativeFunction((a, t) => _inverse(_arg(a, 0))),
    'TINV': NativeFunction((a, t) {
      final p = _numeric(_arg(a, 0), 'TINV', 'probability'),
          df = _integer(_arg(a, 1), 'TINV', 'degrees_of_freedom');
      if (p <= 0 || p > 1 || df < 1)
        throw JsError(
          'TINV() requires 0 < probability <= 1 and degrees_of_freedom >= 1',
        );
      return studentTInverse(p.toDouble(), df);
    }),
    'RANDBETWEEN': NativeFunction((a, t) {
      num parse(dynamic v, String parameter) {
        _required(v, 'RANDBETWEEN', parameter);
        final m = RegExp(r'^[+-]?\d+').firstMatch(jsString(v).trimLeft());
        return m == null ? double.nan : jsNumber(m[0]);
      }

      final low = parse(_arg(a, 0), 'min'), high = parse(_arg(a, 1), 'max');
      if (!low.isFinite || !high.isFinite || high < low)
        throw JsError(
          'RANDBETWEEN() expects valid integer bounds with min <= max',
        );
      return (random.nextDouble() * (high - low + 1)).floor() + low;
    }),
    'FIND_REF_SETTING': NativeFunction((a, t) {
      final setting = _required(_arg(a, 0), 'FIND_REF_SETTING', 'ref_setting'),
          vertical = _numeric(_arg(a, 1), 'FIND_REF_SETTING', 'vertical_value'),
          horizontal = _arg(a, 2);
      final rows = _array(_field(setting, 'rows'), 'MATCH');
      final r = matchValue(vertical, rows),
          c = identical(horizontal, undefined)
              ? 0
              : matchValue(
                  _numeric(horizontal, 'FIND_REF_SETTING', 'horizontal_value'),
                  _array(_field(setting, 'columns'), 'MATCH'),
                );
      if (r < 0 || c < 0) return null;
      final data = _array(_field(setting, 'datas'), 'FIND_REF_SETTING');
      final found = jsNumber(_field(_field(data, r), c));
      if (jsNumber(rows[r]) == vertical || r + 1 >= data.length) return found;
      return math.max(found, jsNumber(_field(data[r + 1], c)));
    }),
    'FIND_STD_ERROR': NativeFunction((a, t) {
      final records = standards(_arg(a, 0));
      if (records.isEmpty) return null;
      final point = _arg(a, 1);
      if (identical(point, undefined)) return records.first;
      final p = _numeric(point, 'FIND_STD_ERROR', 'lookup_value');
      final values = records.map((v) => jsNumber(_field(v, 'value'))).toList();
      if (p < values.first || p > values.last) return null;
      final r = matchValue(p, values), field = _arg(a, 2, 'uncertainty');
      final returnIndex = truthy(_arg(a, 3, false));
      if (!truthy(field) && returnIndex) return r;
      var i = r;
      if (values[r] != p &&
          r + 1 < records.length &&
          jsNumber(_field(records[r + 1], field)) >
              jsNumber(_field(records[r], field)))
        i = r + 1;
      return returnIndex ? i : records[i];
    }),
    'GET_STD_BY_INDEX': NativeFunction((a, t) {
      final records = standards(_arg(a, 0)),
          index = _required(_arg(a, 1), 'GET_STD_BY_INDEX', 'index'),
          column = _arg(a, 2);
      if ((index == null || identical(index, false)) &&
          !identical(column, undefined))
        return records.map((v) => _field(v, column)).toList();
      final i = _integer(index, 'GET_STD_BY_INDEX', 'index');
      return i < 0 || i >= records.length ? null : records[i];
    }),
    'GET_STD_BY_VALUE': NativeFunction((a, t) {
      final records = standards(_arg(a, 0));
      for (final record in records) {
        if (jsNumber(_field(record, 'value')) ==
            _numeric(_arg(a, 1), 'GET_STD_BY_VALUE', 'value'))
          return record;
      }
      return null;
    }),
    'UNIT': NativeFunction((a, t) {
      final id = _required(_arg(a, 0), 'UNIT', 'unit_id'),
          units = envValue('_UNIT_', {});
      if (units is Map && units.containsKey(jsString(id)))
        return units[jsString(id)];
      final provider = services?.getUnitById;
      if (provider == null)
        throw JsError(
          'Unit service is not configured: provide services.getUnitById or _UNIT_',
        );
      return normalizeUnit(_sync(provider(id), 'UNIT'));
    }),
    'UNIT_ID': NativeFunction((a, t) {
      final name = _required(_arg(a, 0), 'UNIT_ID', 'unit_name'),
          provider = services?.getUnitByName;
      if (provider == null)
        throw JsError(
          'Unit service is not configured: provide services.getUnitByName',
        );
      final unit = _sync(provider(name), 'UNIT_ID');
      if (unit == null) return null;
      final id = _field(unit, 'unit_id');
      final fallback = _field(unit, 'ID');
      return isNullish(id) ? (isNullish(fallback) ? null : fallback) : id;
    }),
    'UNIT_CONVERT': NativeFunction((a, t) {
      final from = _required(_arg(a, 0), 'UNIT_CONVERT', 'from_unit_id'),
          to = _required(_arg(a, 1), 'UNIT_CONVERT', 'to_unit_id'),
          v = _numeric(_arg(a, 2), 'UNIT_CONVERT', 'from_value'),
          provider = services?.convertUnit;
      if (provider == null)
        throw JsError(
          'Unit service is not configured: provide services.convertUnit',
        );
      return _sync(provider(from, to, v), 'UNIT_CONVERT');
    }),
    'GOAL_SEEK': NativeFunction((a, t) {
      final fn = _arg(a, 0);
      if (fn is! JsCallable && fn is! Function)
        throw JsError('GOAL_SEEK() <function> must be a function');
      final goal = _numeric(_arg(a, 1), 'GOAL_SEEK', 'target'),
          tol = _numeric(_arg(a, 2, 1e-6), 'GOAL_SEEK', 'tolerance'),
          iterations = _integer(_arg(a, 3, 100), 'GOAL_SEEK', 'maxIterations');
      if (tol <= 0 || iterations <= 0)
        throw JsError(
          'GOAL_SEEK() tolerance and maxIterations must be positive',
        );
      num evaluate(num x) {
        final dynamic value = fn is InterpreterFunction
            ? fn.interpreter.callFunction(fn, [x], undefined)
            : fn is JsCallable
            ? fn.invoke([x], undefined)
            : Function.apply(fn as Function, [x]);
        return _numeric(
              _sync(value, 'GOAL_SEEK'),
              'GOAL_SEEK',
              'callback result',
            ) -
            goal;
      }

      final f0 = evaluate(0);
      if (f0.abs() <= tol) return 0;
      var low = 0.0, high = 0.0, step = 1.0, found = false;
      for (var i = 0; i < iterations; i++) {
        if (evaluate(-step).sign != f0.sign) {
          low = -step;
          high = 0;
          found = true;
          break;
        }
        if (evaluate(step).sign != f0.sign) {
          low = 0;
          high = step;
          found = true;
          break;
        }
        step *= 2;
      }
      if (!found) throw JsError('Goal Seek: target could not be found');
      var fLow = evaluate(low);
      for (var i = 0; i < iterations; i++) {
        final mid = (low + high) / 2, fMid = evaluate(mid);
        if (fMid.abs() <= tol) return mid;
        if (fLow.sign != fMid.sign) {
          high = mid;
        } else {
          low = mid;
          fLow = fMid;
        }
      }
      throw JsError('Goal Seek: did not converge within maxIterations');
    }),
  };
}
