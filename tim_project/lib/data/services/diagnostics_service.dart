// ============================================================
// lib/data/services/diagnostics_service.dart
// v0.3.6 — one-click self-test of the entire T.I.M. stack.
//
// "Can you test everything if I give you the .exe?" — no remote
// environment can exercise this app's FFI/audio/OCR stack, but the
// app can test ITSELF on the real hardware. Each check returns
// PASS / FAIL / SKIP with details; the combined report is copyable
// so it can be pasted straight into a debugging conversation.
//
// Checks:
//   1. llama.dll present next to the executable
//   2. At least one .gguf model downloaded
//   3. LLM loaded + live generation micro-benchmark (tokens/sec)
//   4. Voice models installed (VAD/STT/TTS/speaker)
//   5. Voice engine initialised
//   6. TTS → STT round trip (speaks a phrase to itself and checks
//      it can transcribe it back — closed loop, no mic needed)
//   7. Microphone capture (1.5 s) + input level
//   8. Screen capture + Windows OCR round trip
//   9. Local vault unlocked + write/read probe
//  10. Cloud session state (skipped in offline-only mode)
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/utils/logger.dart';
import 'llm_engine.dart';
import 'local_vault.dart';
import 'native_worker.dart';
import 'windows_ocr.dart';

enum DiagStatus { pass, fail, skip }

class DiagResult {
  DiagResult(this.name, this.status, this.detail);
  final String name;
  final DiagStatus status;
  final String detail;

  String get icon => switch (status) {
        DiagStatus.pass => '[PASS]',
        DiagStatus.fail => '[FAIL]',
        DiagStatus.skip => '[SKIP]',
      };
}

class DiagnosticsService {
  DiagnosticsService({
    required this.worker,
    required this.llm,
    required this.vault,
    required this.cloudSyncEnabled,
    required this.hasCloudSession,
  }) : _log = Logger('Diagnostics');

  final NativeWorker worker;
  final LlmEngine llm;
  final LocalVault? vault;
  final bool cloudSyncEnabled;
  final bool hasCloudSession;
  final Logger _log;

  /// Run everything. Emits results one by one so the UI can render
  /// progress live.
  Stream<DiagResult> run() async* {
    yield await _checkLlamaDll();
    yield await _checkGgufPresent();
    yield await _checkLlmGeneration();
    yield await _checkVoiceModels();
    yield _checkVoiceEngine();
    yield await _checkTtsSttRoundTrip();
    yield await _checkMicrophone();
    yield await _checkScreenOcr();
    yield _checkVault();
    yield _checkCloud();
  }

  Future<DiagResult> _checkLlamaDll() async {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final path = p.join(exeDir, 'llama.dll');
      if (File(path).existsSync()) {
        final sizeMb =
            (File(path).lengthSync() / (1024 * 1024)).toStringAsFixed(1);
        return DiagResult('llama.dll', DiagStatus.pass,
            'Found beside the executable ($sizeMb MB).');
      }
      return DiagResult('llama.dll', DiagStatus.fail,
          'Not found beside the executable. Run: flutter clean && flutter run -d windows.');
    } catch (e) {
      return DiagResult('llama.dll', DiagStatus.fail, '$e');
    }
  }

  Future<DiagResult> _checkGgufPresent() async {
    try {
      final support = await getApplicationSupportDirectory();
      final modelsDir = Directory(p.join(support.path, 'models'));
      if (!modelsDir.existsSync()) {
        return DiagResult('LLM model file', DiagStatus.fail,
            'Models folder missing — download a model from the top bar.');
      }
      final ggufs = modelsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.gguf'))
          .toList();
      if (ggufs.isEmpty) {
        return DiagResult('LLM model file', DiagStatus.fail,
            'No .gguf downloaded yet — use the model manager in the top bar.');
      }
      final names = ggufs
          .map((f) =>
              '${p.basename(f.path)} (${(f.lengthSync() / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB)')
          .join(', ');
      return DiagResult('LLM model file', DiagStatus.pass, names);
    } catch (e) {
      return DiagResult('LLM model file', DiagStatus.fail, '$e');
    }
  }

  Future<DiagResult> _checkLlmGeneration() async {
    if (!llm.isLoaded) {
      return DiagResult('LLM generation', DiagStatus.skip,
          'No model loaded in this session — load one and re-run.');
    }
    try {
      final sw = Stopwatch()..start();
      var tokens = 0;
      await for (final _ in llm
          .generate('<|im_start|>user\nSay OK.<|im_end|>\n<|im_start|>assistant\n',
              maxTokens: 16, stop: const ['<|im_end|>'])
          .timeout(const Duration(seconds: 90))) {
        tokens++;
      }
      sw.stop();
      if (tokens == 0) {
        return DiagResult(
            'LLM generation', DiagStatus.fail, 'Model produced no tokens.');
      }
      final tps = tokens / (sw.elapsedMilliseconds / 1000.0);
      final verdict = tps < 3
          ? ' — very slow. If this is a DEBUG build, that is the cause '
              '(see note); otherwise use a smaller model.'
          : (tps < 8 ? ' — usable.' : ' — good.');
      final debugNote = kDebugMode
          ? '\n       NOTE: this is a DEBUG build — llama.dll is compiled '
              'without optimisations. Run '
              '"flutter run -d windows --release" for real performance '
              '(typically 5-15x faster).'
          : '';
      return DiagResult('LLM generation', DiagStatus.pass,
          '$tokens tokens in ${sw.elapsedMilliseconds} ms '
          '(${tps.toStringAsFixed(1)} tok/s)$verdict$debugNote');
    } on TimeoutException {
      return DiagResult('LLM generation', DiagStatus.fail,
          'Timed out after 90 s — model may be too large for this machine.');
    } catch (e) {
      return DiagResult('LLM generation', DiagStatus.fail, '$e');
    }
  }

  Future<DiagResult> _checkVoiceModels() async {
    try {
      final support = await getApplicationSupportDirectory();
      final marker = Directory(p.join(support.path, 'voice_models'));
      if (!marker.existsSync() || marker.listSync().isEmpty) {
        return DiagResult('Voice models', DiagStatus.fail,
            'Not downloaded — they auto-download on launch; check the chat for progress or restart the app.');
      }
      final totalMb = marker
              .listSync(recursive: true)
              .whereType<File>()
              .fold<int>(0, (a, f) => a + f.lengthSync()) /
          (1024 * 1024);
      return DiagResult('Voice models', DiagStatus.pass,
          '${totalMb.toStringAsFixed(0)} MB installed.');
    } catch (e) {
      return DiagResult('Voice models', DiagStatus.fail, '$e');
    }
  }

  DiagResult _checkVoiceEngine() {
    if (worker.isReady) {
      return DiagResult('Voice engine', DiagStatus.pass,
          'sherpa-onnx initialised (VAD + STT + TTS'
          '${worker.voiceLockEnrolled ? ' + Voice Lock enrolled' : ''}).');
    }
    return DiagResult('Voice engine', DiagStatus.fail,
        'Not initialised — models missing or init error; check logs.');
  }

  /// The killer test: T.I.M. speaks a phrase and listens to itself.
  /// Exercises TTS synthesis AND STT decoding with zero hardware.
  Future<DiagResult> _checkTtsSttRoundTrip() async {
    if (!worker.isReady) {
      return DiagResult(
          'TTS→STT round trip', DiagStatus.skip, 'Voice engine not ready.');
    }
    try {
      final text = await worker
          .selfTestVoiceLoop('testing one two three')
          .timeout(const Duration(seconds: 60));
      // Whisper often normalises number words to digits ("one" -> "1").
      // Both are correct recognition — accept either form.
      final heard = text
          .toLowerCase()
          .replaceAll('1', ' one ')
          .replaceAll('2', ' two ')
          .replaceAll('3', ' three ');
      final hits = ['testing', 'one', 'two', 'three']
          .where((w) => heard.contains(w))
          .length;
      if (hits >= 3) {
        return DiagResult('TTS→STT round trip', DiagStatus.pass,
            'Spoke a phrase and transcribed it back as: "$text"');
      }
      return DiagResult('TTS→STT round trip', DiagStatus.fail,
          'Heard "$text" — synthesis or recognition is degraded.');
    } catch (e) {
      return DiagResult('TTS→STT round trip', DiagStatus.fail, '$e');
    }
  }

  Future<DiagResult> _checkMicrophone() async {
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        return DiagResult('Microphone', DiagStatus.fail,
            'Permission denied — allow microphone access in Windows Settings → Privacy.');
      }
      final stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      final buf = <int>[];
      final sub = stream.listen(buf.addAll);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await sub.cancel();
      await rec.stop();
      if (buf.length < 16000) {
        return DiagResult('Microphone', DiagStatus.fail,
            'Captured almost no audio (${buf.length} bytes in 1.5 s).');
      }
      final bd = ByteData.sublistView(Uint8List.fromList(buf));
      var sum = 0.0;
      final n = buf.length ~/ 2;
      for (var i = 0; i < n; i++) {
        final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
        sum += v * v;
      }
      final rms = (sum / n).clamp(0, 1);
      return DiagResult('Microphone', DiagStatus.pass,
          'Captured ${(buf.length / 32000.0).toStringAsFixed(1)} s of audio '
          '(level ${(rms * 1000).toStringAsFixed(2)} — silence near 0 is fine if you were quiet).');
    } catch (e) {
      return DiagResult('Microphone', DiagStatus.fail, '$e');
    } finally {
      rec.dispose();
    }
  }

  Future<DiagResult> _checkScreenOcr() async {
    try {
      const channel = MethodChannel('tim.screen/capture');
      final png = await channel
          .invokeMethod<Uint8List>('capture')
          .timeout(const Duration(seconds: 15));
      if (png == null || png.isEmpty) {
        return DiagResult(
            'Screen capture + OCR', DiagStatus.fail, 'Capture returned nothing.');
      }
      final text = await WindowsOcr.extractText(png);
      if (text == null || text.trim().length < 20) {
        return DiagResult('Screen capture + OCR', DiagStatus.fail,
            'Captured ${(png.length / 1024).toStringAsFixed(0)} KB but OCR read '
            '${text?.trim().length ?? 0} chars — Windows OCR may be unavailable.');
      }
      return DiagResult('Screen capture + OCR', DiagStatus.pass,
          'Captured ${(png.length / 1024).toStringAsFixed(0)} KB, OCR read '
          '${text.trim().length} chars from the current screen.');
    } catch (e) {
      return DiagResult('Screen capture + OCR', DiagStatus.fail, '$e');
    }
  }

  DiagResult _checkVault() {
    final v = vault;
    if (v == null) {
      return DiagResult('Local vault', DiagStatus.fail,
          'Vault not unlocked — sign in first.');
    }
    try {
      final probeId = 'diag_${DateTime.now().microsecondsSinceEpoch}';
      v.insertChatMessage(
          id: probeId, sender: 'system', text: 'diag-probe', workspace: '__diag__');
      final rows = v.loadChatHistory(workspace: '__diag__', limit: 1);
      if (rows.isEmpty) {
        return DiagResult(
            'Local vault', DiagStatus.fail, 'Write succeeded but read failed.');
      }
      return DiagResult('Local vault', DiagStatus.pass,
          'SQLite write/read round trip OK.');
    } catch (e) {
      return DiagResult('Local vault', DiagStatus.fail, '$e');
    }
  }

  DiagResult _checkCloud() {
    if (!cloudSyncEnabled) {
      return DiagResult('Cloud sync', DiagStatus.skip,
          'Offline-only mode is ON — nothing leaves this PC (by design).');
    }
    return hasCloudSession
        ? DiagResult('Cloud sync', DiagStatus.pass, 'Signed-in session active.')
        : DiagResult('Cloud sync', DiagStatus.fail,
            'Sync enabled but no active session — sign in again.');
  }

  /// Plain-text report for copy/paste.
  static String reportText(List<DiagResult> results) {
    final b = StringBuffer()
      ..writeln('T.I.M. self-diagnostic — ${DateTime.now().toIso8601String()}')
      ..writeln('OS: ${Platform.operatingSystemVersion}')
      ..writeln('Cores: ${Platform.numberOfProcessors}')
      ..writeln('-' * 60);
    for (final r in results) {
      b.writeln('${r.icon} ${r.name}');
      b.writeln('       ${r.detail}');
    }
    final fails = results.where((r) => r.status == DiagStatus.fail).length;
    b
      ..writeln('-' * 60)
      ..writeln('${results.length} checks — '
          '${results.where((r) => r.status == DiagStatus.pass).length} pass, '
          '$fails fail, '
          '${results.where((r) => r.status == DiagStatus.skip).length} skipped.');
    return b.toString();
  }
}
