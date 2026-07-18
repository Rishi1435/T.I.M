// ============================================================
// lib/data/services/screen_watcher.dart
// Phase 6 — Event-Driven Screen Watching.
//
// Triggered ONLY by an explicit voice command ("T.I.M., look at my
// screen"). The app takes a screenshot, downscales it, and sends it
// to the Python worker which runs it through Moondream2.
//
// T.I.M. does NOT write code for the user. It highlights logical
// flaws and guides them to the solution.
// ============================================================

import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/logger.dart';
import 'native_worker.dart';

class ScreenWatcher {
  ScreenWatcher(this._ws) : _log = Logger('ScreenWatcher');

  final NativeWorker _ws;
  final Logger _log;

  /// Trigger phrases that activate screen watching.
  static const triggers = [
    'look at my screen',
    'check my screen',
    "what's on my screen",
    'review my screen',
    'screen watch',
  ];

  /// Returns true if [transcript] contains a screen-watch trigger.
  static bool isTriggered(String transcript) {
    final lower = transcript.toLowerCase();
    return triggers.any((t) => lower.contains(t));
  }

  /// Capture the screen and forward to the Python worker for Moondream2
  /// analysis. The native screenshot call is handled by a separate
  /// MethodChannel (`tim.screen/capture`) registered in the Windows
  /// runner — see windows/runner/README.md.
  ///
  /// Returns the worker's textual analysis (highlighted flaws + hints).
  Future<String> captureAndAnalyse({
    required Future<Uint8List> Function() capture,
    String prompt = 'Identify logical flaws in the code or design on '
                    'screen. Do NOT write code. List 2-3 hints.',
  }) async {
    _log.info('Screen watch triggered.');
    final png = await capture();

    // Send a JSON control envelope asking the worker to run Moondream2.
    _ws.sendJson({
      'type': 'screen_vision',
      'prompt': prompt,
      'image_bytes': png.length,
    });
    // Then the raw PNG bytes.
    _ws.sendAudio(png);

    // Wait for the worker's `screen_vision` response (single-shot).
    final completer = Completer<String>();
    final sub = _ws.events
        .where((e) => e.type == WsEventType.screenVision)
        .listen((e) {
      final text = e.payload['analysis'] as String? ??
          '<no analysis returned>';
      if (!completer.isCompleted) completer.complete(text);
    });
    // Timeout safety: 20s.
    Future.delayed(const Duration(seconds: 20), () {
      if (!completer.isCompleted) {
        completer.complete('<screen analysis timed out>');
      }
    });
    final result = await completer.future;
    await sub.cancel();
    _log.info('Screen analysis received (${result.length} chars).');
    return result;
  }
}
