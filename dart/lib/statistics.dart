// Dart adaptation of jStat 1.9.6 special functions and Student t inverse.
// Copyright (c) 2013 jStat. MIT license: ../JSTAT_LICENSE.
import 'dart:math' as math;

double _gammaLn(double x) {
  const coefficients = [
    76.18009172947146,
    -86.50532032941677,
    24.01409824083091,
    -1.231739572450155,
    0.001208650973866179,
    -0.000005395239384953,
  ];
  var y = x;
  var temporary = x + 5.5;
  temporary -= (x + 0.5) * math.log(temporary);
  var series = 1.000000000190015;
  for (final coefficient in coefficients) {
    y++;
    series += coefficient / y;
  }
  return math.log(2.5066282746310005 * series / x) - temporary;
}

double _betaFraction(double x, double a, double b) {
  const minimum = 1e-30;
  final qab = a + b, qap = a + 1, qam = a - 1;
  var c = 1.0, d = 1 - qab * x / qap;
  if (d.abs() < minimum) d = minimum;
  d = 1 / d;
  var h = d;
  for (var m = 1; m <= 100; m++) {
    final m2 = 2 * m;
    var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
    d = 1 + aa * d;
    if (d.abs() < minimum) d = minimum;
    c = 1 + aa / c;
    if (c.abs() < minimum) c = minimum;
    d = 1 / d;
    h *= d * c;
    aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
    d = 1 + aa * d;
    if (d.abs() < minimum) d = minimum;
    c = 1 + aa / c;
    if (c.abs() < minimum) c = minimum;
    d = 1 / d;
    final delta = d * c;
    h *= delta;
    if ((delta - 1).abs() < 3e-7) break;
  }
  return h;
}

double _beta(double x, double a, double b) {
  final factor = x == 0 || x == 1
      ? 0.0
      : math.exp(
          _gammaLn(a + b) -
              _gammaLn(a) -
              _gammaLn(b) +
              a * math.log(x) +
              b * math.log(1 - x),
        );
  if (x < (a + 1) / (a + b + 2)) return factor * _betaFraction(x, a, b) / a;
  return 1 - factor * _betaFraction(1 - x, b, a) / b;
}

double _inverseBeta(double p, double a, double b) {
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  final a1 = a - 1, b1 = b - 1;
  double x;
  if (a >= 1 && b >= 1) {
    final pp = p < 0.5 ? p : 1 - p;
    final t = math.sqrt(-2 * math.log(pp));
    x = (2.30753 + t * 0.27061) / (1 + t * (0.99229 + t * 0.04481)) - t;
    if (p < 0.5) x = -x;
    final al = (x * x - 3) / 6;
    final h = 2 / (1 / (2 * a - 1) + 1 / (2 * b - 1));
    final w =
        x * math.sqrt(al + h) / h -
        (1 / (2 * b - 1) - 1 / (2 * a - 1)) * (al + 5 / 6 - 2 / (3 * h));
    x = a / (a + b * math.exp(2 * w));
  } else {
    final t = math.exp(a * math.log(a / (a + b))) / a;
    final u = math.exp(b * math.log(b / (a + b))) / b;
    final w = t + u;
    x = p < t / w
        ? math.pow(a * w * p, 1 / a).toDouble()
        : 1 - math.pow(b * w * (1 - p), 1 / b).toDouble();
  }
  final factor = -_gammaLn(a) - _gammaLn(b) + _gammaLn(a + b);
  for (var j = 0; j < 10; j++) {
    if (x == 0 || x == 1) return x;
    final error = _beta(x, a, b) - p;
    final derivative = math.exp(
      a1 * math.log(x) + b1 * math.log(1 - x) + factor,
    );
    final u = error / derivative;
    final step = u / (1 - 0.5 * math.min(1, u * (a1 / x - b1 / (1 - x))));
    x -= step;
    if (x <= 0) x = 0.5 * (x + step);
    if (x >= 1) x = 0.5 * (x + step + 1);
    if (step.abs() < 1e-8 * x && j > 0) break;
  }
  return x;
}

/// Same two-tailed convention as TINV in lib/functions.ts.
double studentTInverse(double probability, int degreesOfFreedom) {
  if (probability == 1) return 0;
  // Follow the TS 1-p/2 rounding, including its floating-point boundary behavior.
  final p = 1 - probability / 2;
  final x = _inverseBeta(2 * math.min(p, 1 - p), degreesOfFreedom / 2, 0.5);
  return math.sqrt(degreesOfFreedom * (1 - x) / x);
}
