// ============================================================
// lib/data/services/speech_analytics.dart
// Phase 5 — Speech Analytics.
//
// Tracks timestamps between words to flag:
//   - "air gaps"   : pauses > 800ms mid-utterance
//   - filler words : "um", "uh", "like", "you know", "basically"
//   - pitch shifts : rapid rises indicate anxiety (heuristic)
//
// The backend Python worker emits `speech_analytics` events over WS;
// this service is the Dart-side decoder + interruption-policy gate.
// ============================================================

import '../../core/utils/logger.dart';

class SpeechFrame {
  SpeechFrame({
    required this.word,
    required this.startMs,
    required this.endMs,
    required this.pitchHz,
  });
  final String word;
  final int startMs;
  final int endMs;
  final double pitchHz;
}

class SpeechReport {
  SpeechReport({
    required this.fillerCount,
    required this.airGapCount,
    required this.pitchVariance,
    required this.cadenceWpm,
    required this.flags,
  });
  final int fillerCount;
  final int airGapCount;
  final double pitchVariance;
  final double cadenceWpm;
  final List<String> flags;
}

class SpeechAnalytics {
  SpeechAnalytics() : _log = Logger('SpeechAnalytics');

  final Logger _log;

  static const _fillers = {
    'um', 'uh', 'er', 'ah', 'like', 'you know', 'basically',
    'actually', 'literally', 'sort of', 'kind of',
  };

  /// Analyse a sequence of [SpeechFrame]s produced by the STT layer.
  SpeechReport analyse(List<SpeechFrame> frames) {
    if (frames.isEmpty) {
      return SpeechReport(
        fillerCount: 0,
        airGapCount: 0,
        pitchVariance: 0,
        cadenceWpm: 0,
        flags: [],
      );
    }

    var fillers = 0;
    var airGaps = 0;
    final pitches = <double>[];

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (_fillers.contains(f.word.toLowerCase())) fillers++;
      pitches.add(f.pitchHz);
      if (i > 0) {
        final gap = f.startMs - frames[i - 1].endMs;
        if (gap > 800) airGaps++;
      }
    }

    final mean = pitches.reduce((a, b) => a + b) / pitches.length;
    final variance = pitches.isEmpty
        ? 0.0
        : pitches.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) /
            pitches.length;
    final cadence = frames.length /
        ((frames.last.endMs - frames.first.startMs) / 60000.0);

    final flags = <String>[];
    if (fillers > 3) flags.add('too_many_fillers');
    if (airGaps > 2) flags.add('excessive_air_gaps');
    if (variance > 800) flags.add('pitch_anxiety');
    if (cadence < 90) flags.add('too_slow');
    if (cadence > 200) flags.add('too_fast');

    _log.info('SpeechReport: fillers=$fillers gaps=$airGaps '
              'pitchVar=${variance.toStringAsFixed(0)} wpm=${cadence.toStringAsFixed(0)} '
              'flags=$flags');

    return SpeechReport(
      fillerCount: fillers,
      airGapCount: airGaps,
      pitchVariance: variance,
      cadenceWpm: cadence,
      flags: flags,
    );
  }

  /// Decide whether T.I.M. should interrupt the user mid-speech to
  /// correct their cadence. Returns the corrective message or null.
  String? interruptionMessage(SpeechReport r) {
    if (r.flags.contains('too_many_fillers')) {
      return 'You\'ve said "um" a few times. Pause, breathe, and continue.';
    }
    if (r.flags.contains('excessive_air_gaps')) {
      return 'You\'re trailing off. Land your sentence with confidence.';
    }
    if (r.flags.contains('pitch_anxiety')) {
      return 'Your pitch is jumping — slow down, lower your shoulders.';
    }
    if (r.flags.contains('too_fast')) {
      return 'Too fast. Drop to ~140 wpm so the interviewer can follow.';
    }
    return null;
  }
}
