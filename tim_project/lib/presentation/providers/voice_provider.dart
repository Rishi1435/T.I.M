// ============================================================
// lib/presentation/providers/voice_provider.dart
// Phase 5 — Live Call View state.
//
// Owns the live waveform animation values + the speech-analytics
// report stream. The Live Call overlay watches this provider.
// ============================================================

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../data/services/speech_analytics.dart';
import '../../data/services/websocket_service.dart';
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

  final WebSocketService _ws;
  final SpeechAnalytics _analytics;
  late final StreamSubscription<WsEvent> _sub;
  late final Timer _timer;
  final _rng = Random();

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

  /// 20Hz ticker that drives the waveform animation. In production
  /// the decibel value comes from the mic capture stream; here we
  /// synthesise a plausible wave so the UI can be demoed offline.
  void _tick(Timer t) {
    if (!state.active) return;
    final db = 0.3 + _rng.nextDouble() * 0.7;
    final wave = List<double>.generate(48, (_) => _rng.nextDouble());
    state = state.copyWith(decibel: db, waveform: wave);
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
