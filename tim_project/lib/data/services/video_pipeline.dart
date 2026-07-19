// ============================================================
// lib/data/services/video_pipeline.dart
// Phase 6 — Video / Presentation coaching.
//
// The backend Python worker bundles FFmpeg and extracts one frame
// every 3 seconds from an uploaded MP4. T.I.M. then analyses those
// frames alongside the user's audio to coach on:
//   - slide pacing (time-per-slide)
//   - presentation structure (intro / body / close)
//   - body language (via audio energy + frame variance)
//
// This Dart service dispatches the work to the Python worker over WS
// and aggregates the response into a [VideoCoachReport].
// ============================================================

import 'dart:async';

import '../../core/utils/logger.dart';
import 'native_worker.dart';

class VideoCoachReport {
  VideoCoachReport({
    required this.frameCount,
    required this.durationSec,
    required this.slidePaceSecPerSlide,
    required this.summary,
  });
  final int frameCount;
  final int durationSec;
  final double slidePaceSecPerSlide;
  final String summary;
}

class VideoPipeline {
  VideoPipeline(this._ws) : _log = Logger('VideoPipeline');

  final NativeWorker _ws;
  final Logger _log;

  /// Request frame extraction + analysis for a local MP4.
  Future<VideoCoachReport> analyse(String mp4Path) async {
    _log.info('Dispatching video pipeline for $mp4Path');
    _ws.sendJson({
      'type': 'video_pipeline',
      'path': mp4Path,
      'frame_interval_sec': 3,
    });

    final completer = Completer<VideoCoachReport>();
    final sub = _ws.events
        .where((e) => e.type == WsEventType.screenVision)
        .listen((e) {
      // Worker reuses the screen_vision channel for video frames.
      // The final aggregate is sent as a `screen_vision` event with
      // `kind=video_summary`.
      if (e.payload['kind'] != 'video_summary') return;
      final report = VideoCoachReport(
        frameCount: e.payload['frame_count'] as int? ?? 0,
        durationSec: e.payload['duration_sec'] as int? ?? 0,
        slidePaceSecPerSlide:
            (e.payload['slide_pace_sec_per_slide'] as num?)?.toDouble() ?? 0,
        summary: e.payload['summary'] as String? ?? '',
      );
      if (!completer.isCompleted) completer.complete(report);
    });
    Future.delayed(const Duration(minutes: 2), () {
      if (!completer.isCompleted) {
        completer.complete(VideoCoachReport(
          frameCount: 0,
          durationSec: 0,
          slidePaceSecPerSlide: 0,
          summary: '<video pipeline timed out>',
        ),);
      }
    });
    final r = await completer.future;
    await sub.cancel();
    return r;
  }
}
