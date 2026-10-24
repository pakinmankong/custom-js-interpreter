// Backwards-compatible entry point. New code can import functions.dart directly.
import 'env.dart';
import 'functions.dart';
export 'functions.dart';
export 'base_functions.dart' show flattenValues;

Map<String, dynamic> createExampleFunctions({
  void Function(List<dynamic>)? output,
  Env Function()? getEnv,
  FunctionServices? services,
}) => createFunctions(output: output, getEnv: getEnv, services: services);
