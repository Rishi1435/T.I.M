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
  });

  final bool active;
  final double decibel; // 0..1 normalised
  final List<double> waveform; // last N samples for the animation
  final SpeechReport? lastReport;
  final String? interruptionMessage;

  VoiceCallState copyWith({
    bool? active,
    double? decibel,
    List<double>? waveform,
    SpeechReport? lastReport,
    String? interruptionMessage,
  }) =>
      VoiceCallState(
        active: active ?? this.active,
        decibel: decibel ?? this.decibel,
        waveform: waveform ?? this.waveform,
        lastReport: lastReport ?? this.lastReport,
        interruptionMessage: interruptionMessage ?? this.interruptionMessage,
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

  void startCall() => state = state.copyWith(active: true);
  void stopCall() =>
      state = const VoiceCallState();

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
