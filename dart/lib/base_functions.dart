// Host functions ported from index.ts. Kept opt-in, as in the TS context.
import 'dart:math' as math;
import 'errors.dart';
import 'runtime.dart';

List<dynamic> flattenValues(List<dynamic> values) => [
  for (final value in values) ...value is List ? flattenValues(value) : [value],
];
Map<String, dynamic> createBaseFunctions({
  void Function(List<dynamic>)? output,
}) {
  final random = math.Random();
  dynamic arg(List<dynamic> args, int i, [dynamic fallback = undefined]) =>
      i < args.length && !identical(args[i], undefined) ? args[i] : fallback;
  num number(List<dynamic> args, int i, String name) {
    final value = arg(args, i);
    if (identical(value, undefined))
      throw JsError('function $name expects argument ${i + 1}');
    final result = jsNumber(value);
    if (result.isNaN)
      throw JsError(
        'function $name expects a numeric argument, but received: ${jsString(value)}',
      );
    return result;
  }

  List<num> numbers(List<dynamic> args) =>
      flattenValues(args).map((v) => jsNumber(truthy(v) ? v : 0)).toList();
  return {
    'print': NativeFunction((args, receiver) {
      output?.call(args);
      return undefined;
    }),
    'EMPTY': NativeFunction((args, receiver) {
      final v = arg(args, 0);
      return isNullish(v) || jsString(truthy(v) ? v : '').trim().isEmpty;
    }),
    'ERROR': NativeFunction((args, receiver) {
      if (args.isEmpty)
        throw JsError(
          'function ERROR(message, [data]) expects at least 1 argument, but 0 were provided',
        );
      return {'type': 'error', 'message': args[0], 'data': arg(args, 1)};
    }),
    'NUMBER': NativeFunction((args, receiver) {
      if (args.isEmpty)
        throw JsError(
          'function NUMBER(value) expects 1 argument, but 0 were provided',
        );
      return jsNumber(args[0]);
    }),
    'IS_INFINITY': NativeFunction(
      (args, receiver) => number(args, 0, 'IS_INFINITY').isInfinite,
    ),
    'FIND_INDEX': NativeFunction((args, receiver) {
      if (args.length < 2 || args[0] is! List)
        throw JsError('FIND_INDEX expects an array and value');
      dynamic normalize(dynamic v) => jsNumber(v).isNaN ? v : jsNumber(v);
      final value = normalize(args[1]);
      return (args[0] as List).indexWhere(
        (v) => strictEqual(normalize(v), value),
      );
    }),
    'DECIMAL_PLACES': NativeFunction((args, receiver) {
      number(args, 0, 'DECIMAL_PLACES');
      final parts = jsString(args[0]).split('.');
      return parts.length > 1 ? parts[1].length : 0;
    }),
    'SIG': NativeFunction(
      (args, receiver) => _significant(
        number(args, 0, 'SIG'),
        jsNumber(arg(args, 1, 2)).toInt(),
      ),
    ),
    'POWER': NativeFunction(
      (args, receiver) =>
          math.pow(number(args, 0, 'POWER'), number(args, 1, 'POWER')),
    ),
    'EXP': NativeFunction((args, receiver) => math.exp(number(args, 0, 'EXP'))),
    'SUM': NativeFunction(
      (args, receiver) => numbers(args).fold<num>(0, (a, b) => a + b),
    ),
    'AVERAGE': NativeFunction((args, receiver) {
      final values = numbers(args);
      return values.fold<num>(0, (a, b) => a + b) / values.length;
    }),
    'STDEV': NativeFunction((args, receiver) {
      final values = flattenValues(args).map(jsNumber).toList();
      if (values.length < 2)
        throw JsError('STDEV(array) requires at least 2 values');
      final mean = values.fold<num>(0, (a, b) => a + b) / values.length;
      return math.sqrt(
        values.fold<num>(0, (a, b) => a + math.pow(b - mean, 2)) /
            (values.length - 1),
      );
    }),
    'SUMSQ': NativeFunction(
      (args, receiver) => numbers(args).fold<num>(0, (a, b) => a + b * b),
    ),
    'TREND': NativeFunction((args, receiver) {
      if (args.length < 3 || args[0] is! List || args[1] is! List)
        throw JsError(
          'function TREND(knownYValues, knownXValues, newXValue) expects 3 arguments',
        );
      final y = (args[0] as List).map(jsNumber).toList();
      final x = (args[1] as List).map(jsNumber).toList();
      final n = x.length;
      final sumX = x.fold<num>(0, (a, b) => a + b),
          sumY = y.fold<num>(0, (a, b) => a + b);
      num xy = 0, x2 = 0;
      for (var i = 0; i < n; i++) {
        xy += x[i] * (i < y.length ? y[i] : double.nan);
        x2 += x[i] * x[i];
      }
      final slope = (n * xy - sumX * sumY) / (n * x2 - sumX * sumX);
      return (sumY - slope * sumX) / n + slope * number(args, 2, 'TREND');
    }),
    'RAND': NativeFunction((args, receiver) => random.nextDouble()),
    'RANDBETWEEN': NativeFunction((args, receiver) {
      final min = number(args, 0, 'RANDBETWEEN'),
          max = number(args, 1, 'RANDBETWEEN');
      return (random.nextDouble() * (max - min + 1)).floor() + min;
    }),
    'MIN': NativeFunction(
      (args, receiver) => numbers(args).fold<num>(double.infinity, math.min),
    ),
    'MAX': NativeFunction(
      (args, receiver) =>
          numbers(args).fold<num>(double.negativeInfinity, math.max),
    ),
    'ABS': NativeFunction((args, receiver) => number(args, 0, 'ABS').abs()),
    'SQRT': NativeFunction(
      (args, receiver) => math.sqrt(number(args, 0, 'SQRT')),
    ),
    'LOG': NativeFunction((args, receiver) {
      final value = number(args, 0, 'LOG');
      final base = arg(args, 1, 10) ?? 10;
      return base == 'e'
          ? math.log(value)
          : math.log(value) / math.log(jsNumber(base));
    }),
    'FIXED': NativeFunction(
      (args, receiver) => number(
        args,
        0,
        'FIXED',
      ).toStringAsFixed(number(args, 1, 'FIXED').toInt()),
    ),
    'ROUND': NativeFunction((args, receiver) {
      final factor = math.pow(10, jsNumber(arg(args, 1, 0)));
      final v = number(args, 0, 'ROUND') * factor;
      return v.isFinite ? (v + 0.5).floor() / factor : v;
    }),
  };
}

String _significant(num input, int figures) {
  if (figures < 1 || figures > 100)
    throw JsError('SIG figures must be between 1 and 100');
  if (input == 0) return '0';
  if (!input.isFinite) return jsString(input);
  final sign = input < 0 ? '-' : '';
  final value = input.abs();
  final exponent = (math.log(value) / math.ln10).floor();
  if (value < 0.1) {
    final scale = math.pow(10, figures - exponent - 1);
    return sign + ((value * scale).ceil() / scale).toStringAsPrecision(figures);
  }
  if (value < 300) {
    final scale = math.pow(10, exponent - figures + 1);
    return sign + ((value / scale).ceil() * scale).toStringAsPrecision(figures);
  }
  var engExp = (exponent / 3).floor() * 3;
  var mantissa = value / math.pow(10, engExp);
  final scale = math.pow(
    10,
    (math.log(mantissa) / math.ln10).floor() - figures + 1,
  );
  mantissa = ((mantissa / scale).ceil() * scale).toDouble();
  while (mantissa >= 100) {
    mantissa /= 1000;
    engExp += 3;
  }
  return '$sign${mantissa.toStringAsPrecision(figures)}E+$engExp';
}
