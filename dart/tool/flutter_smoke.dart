// No dart:io or JavaScript interop: the library can be compiled for VM and web.
import '../lib/custom_js_interpreter.dart';

void main() {
  late final InterpreterService interpreter;
  interpreter = InterpreterService(
    InterpreterContext(
      functions: createFunctions(getEnv: () => interpreter.currentEnv),
      variables: {
        'DATA': {'A': 'return 5'},
      },
    ),
  );
  final value = interpreter.execute('''
    const factor = 2;
    const double = value => value * factor;
    return [1, 2, 3].map(double).reduce((total, value) => total + value, 0) + DATA.A;
  ''');
  if (value != 17) throw StateError('Expected 17, received $value');
  final result =
      interpreter.execute('''
    const factor = 2;
    return [GOAL_SEEK(function(x) { return x * factor; }, 10),
      TINV(0.05, 10), MMULT([[1, 2]], [[3], [4]])[0][0],
      SUM([{v: 2}, {v: 3}], "v")];
  ''')
          as List;
  if ((result[0] - 5).abs() > 1e-6 ||
      (result[1] - 2.2281388519649385).abs() > 1e-6 ||
      result[2] != 11 ||
      result[3] != 5) {
    throw StateError('Formula function smoke test failed: $result');
  }
  final edge =
      interpreter.execute(r'''
    var a=[1,2];delete a[0];
    return [null==false,NUM("0b11"),`x=${`inner${2}`}`,
      0 in a,a.map(x=>x+1).length,"ab".replace(/a/g,(m,i)=>m+i),
      1000000000000000001===1000000000000000000,~4294967295];
  ''')
          as List;
  if (edge[0] != false ||
      edge[1] != 3 ||
      edge[2] != 'x=inner2' ||
      edge[3] != false ||
      edge[4] != 2 ||
      edge[5] != 'a0b' ||
      edge[6] != true ||
      edge[7] != 0) {
    throw StateError('Runtime parity smoke test failed: $edge');
  }
  print('Runtime parity smoke test passed');
  print('Formula functions smoke test passed: $result');
  print('Flutter-compatible library smoke test passed: $value');
}
