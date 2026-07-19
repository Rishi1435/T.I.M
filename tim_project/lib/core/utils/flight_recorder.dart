// ============================================================
// lib/core/utils/flight_recorder.dart
// v0.4.3 — records what REALLY happened, not what tests simulate.
//
// Born from a fair criticism: "maintain a proper diagnosis which
// analyzes the real info instead of the test data." Synthetic checks
// prove components can work; this proves what they actually did.
// Every real send, generation, TTS event, guard trip, and error is
// appended to a rolling in-memory log (300 entries) that ships with
// the Diagnostics report — so "it immediately stops" arrives as a
// timestamped sequence naming the exact step that died.
// ============================================================

class FlightRecorder {
  FlightRecorder._();
  static final FlightRecorder I = FlightRecorder._();

  static const int _cap = 300;
  final List<String> _entries = [];
  String? lastError;

  void log(String event) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _entries.add('$ts  $event');
    if (_entries.length > _cap) _entries.removeAt(0);
  }

  void error(String event) {
    lastError = event;
    log('ERROR  $event');
  }

  String dump({int last = 40}) {
    final slice = _entries.length <= last
        ? _entries
        : _entries.sublist(_entries.length - last);
    return slice.isEmpty ? '(no activity recorded yet)' : slice.join('\n');
  }

  void clear() {
    _entries.clear();
    lastError = null;
  }
}
