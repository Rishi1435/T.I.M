// ============================================================
// lib/core/utils/logger.dart
// Thin wrapper over `developer.log` so we have a single switch to
// flip when wiring a real logging backend (file rotation, Sentry…).
// ============================================================

class Logger {
  Logger(this.name);
  final String name;

  static bool enabled = true;

  static void init() {
    // Future hook point for file-based logging / crash reporting.
  }

  void info(Object? msg) => _log('INFO', msg);
  void warn(Object? msg) => _log('WARN', msg);
  void debug(Object? msg) => _log('DEBUG', msg);
  void error(Object? msg, [Object? error, StackTrace? stack]) =>
      _log('ERROR', msg, error, stack);

  void _log(
    String level,
    Object? msg, [
    Object? error,
    StackTrace? stack,
  ]) {
    if (!enabled) return;
    if (level == 'DEBUG') return;
    print('[$level] [$name] $msg');
    if (error != null) {
      print('  Error: $error');
    }
    if (stack != null) {
      print('  Stack: $stack');
    }
  }
}
