// ============================================================
// lib/presentation/providers/voice_provider.dart
// Phase 5 — Live Call View state.
//
// Owns the live waveform animation values + the speech-analytics
// report stream. The Live Call overlay watches this provider.
// ============================================================

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../data/services/speech_analytics.dart';
import '../../data/services/native_worker.dart';
import 'chat_provider.dart';

@immutable
class VoiceCallState {
  const VoiceCallState({
    this.active = false,
    this.decibel = 0.0,
    this.waveform = const [],
    this.lastReport,
    this.interruptionMessage,
    this.error,
  });

  final bool active;
  final double decibel; // 0..1 normalised
  final List<double> waveform; // last N samples for the animation
  final SpeechReport? lastReport;
  final String? interruptionMessage;
  final String? error;

  VoiceCallState copyWith({
    bool? active,
    double? decibel,
    List<double>? waveform,
    SpeechReport? lastReport,
    String? interruptionMessage,
    String? error,
  }) =>
      VoiceCallState(
        active: active ?? this.active,
        decibel: decibel ?? this.decibel,
        waveform: waveform ?? this.waveform,
        lastReport: lastReport ?? this.lastReport,
        interruptionMessage: interruptionMessage ?? this.interruptionMessage,
        error: error ?? this.error,
      );
}

class VoiceCallController extends StateNotifier<VoiceCallState> {
  VoiceCallController(this._ws, this._analytics)
      : super(const VoiceCallState()) {
    _sub = _ws.events
        .where((e) => e.type == WsEventType.speechAnalytics)
        .listen(_onAnalytics);
    _timer = Timer.periodic(const Duration(milliseconds: 50), _tick);
  }

  final NativeWorker _ws;
  final SpeechAnalytics _analytics;
  late final StreamSubscription<WsEvent> _sub;
  late final Timer _timer;
  // Rolling RMS window driving the real waveform (no more Random()).
  final List<double> _levels = List<double>.filled(48, 0.0, growable: false);
  int _levelIdx = 0;
  double _lastDb = 0.0;

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordSub;

  Future<void> startCall() async {
    if (state.active) return;
    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        state = state.copyWith(error: 'Microphone permission denied');
        return;
      }
      state = state.copyWith(active: true, error: null);

      final recordStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _recordSub = recordStream.listen((data) {
        _ws.sendAudio(data);
        _ingestPcm(data);
      });
    } catch (e) {
      state = state.copyWith(active: false, error: 'Failed to start recording: $e');
    }
  }

  Future<void> stopCall() async {
    if (!state.active) return;
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
    state = const VoiceCallState();
  }

  void _onAnalytics(WsEvent e) {
    final frames = (e.payload['frames'] as List? ?? [])
        .map((f) => SpeechFrame(
              word: (f as Map)['word'] as String? ?? '',
              startMs: (f['start_ms'] as num?)?.toInt() ?? 0,
              endMs: (f['end_ms'] as num?)?.toInt() ?? 0,
              pitchHz: (f['pitch_hz'] as num?)?.toDouble() ?? 0,
            ),)
        .toList();
    final report = _analytics.analyse(frames);
    final msg = _analytics.interruptionMessage(report);
    state = state.copyWith(
      lastReport: report,
      interruptionMessage: msg,
    );
  }

  /// Compute RMS of each mic chunk (16-bit LE PCM) and push it into
  /// the rolling waveform buffer. This is the REAL signal now.
  void _ingestPcm(Uint8List pcm) {
    final bd = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    if (n == 0) return;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = sqrt(sum / n);
    // Perceptual-ish scaling: mic speech RMS ~0.02-0.3 → 0..1.
    _lastDb = (rms * 4.0).clamp(0.0, 1.0);
    _levels[_levelIdx] = _lastDb;
    _levelIdx = (_levelIdx + 1) % _levels.length;
  }

  /// 20Hz ticker publishing the rolling mic levels to the UI.
  void _tick(Timer t) {
    if (!state.active) return;
    final wave = <double>[
      for (var i = 0; i < _levels.length; i++)
        _levels[(_levelIdx + i) % _levels.length],
    ];
    state = state.copyWith(decibel: _lastDb, waveform: wave);
  }

  @override
  void dispose() {
    _recordSub?.cancel();
    _recorder.dispose();
    _sub.cancel();
    _timer.cancel();
    super.dispose();
  }
}

final speechAnalyticsProvider =
    Provider<SpeechAnalytics>((ref) => SpeechAnalytics());

final voiceCallProvider =
    StateNotifierProvider<VoiceCallController, VoiceCallState>(
  (ref) {
    final ws = ref.watch(webSocketProvider);
    final analytics = ref.watch(speechAnalyticsProvider);
    return VoiceCallController(ws, analytics);
  },
);
