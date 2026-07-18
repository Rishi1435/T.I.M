// ============================================================
// lib/data/services/biometric_gate.dart
// Path B — Biometric Voice Lock, done honestly.
//
// Design (fixes the blueprint's 500ms flaw):
//   STAGE 1 (instant): any detected human speech while T.I.M. is
//     talking PAUSES playback within ~200ms. No biometrics needed.
//   STAGE 2 (accurate): once ~1.5s of the interrupting audio has
//     accumulated, the speaker embedding is scored against the
//     enrolled anchor. Owner → T.I.M. yields the floor (interrupt
//     confirmed). Not owner / noise → playback resumes.
//
// Until enrollment completes, the gate runs in OPEN MODE and the UI
// must display "Voice Lock: not enrolled".
//
// The anchor embedding is stored in the app-support dir. Speaker
// embeddings are not invertible to audio, but treat the file as
// sensitive anyway; migrating it into the encrypted vault is a
// tracked TODO.
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';

enum BargeInVerdict { owner, notOwner, openMode }

class BiometricGate {
  BiometricGate({required this.storageDir}) : _log = Logger('BiometricGate');

  final String storageDir;
  final Logger _log;

  /// Cosine-similarity acceptance threshold. Typical operating point
  /// for 3D-Speaker / WeSpeaker embeddings; tune per model with a
  /// few genuine/impostor trials.
  static const double threshold = 0.45;

  /// Minimum interrupting audio (seconds) before Stage-2 scoring.
  static const double minVerifySeconds = 1.5;

  Float32List? _anchor;

  bool get isEnrolled => _anchor != null;

  String get _anchorPath => p.join(storageDir, 'voice_anchor.json');

  Future<void> load() async {
    final f = File(_anchorPath);
    if (!f.existsSync()) return;
    try {
      final obj = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = (obj['embedding'] as List).cast<num>();
      _anchor = Float32List.fromList(list.map((e) => e.toDouble()).toList());
      _log.info('Voice anchor loaded (${_anchor!.length} dims).');
    } catch (e) {
      _log.warn('Voice anchor unreadable, staying in open mode: $e');
    }
  }

  /// Persist an enrollment embedding (mean of several 10s-clip
  /// embeddings works best — the caller averages before saving).
  Future<void> enroll(Float32List embedding) async {
    _anchor = embedding;
    await Directory(storageDir).create(recursive: true);
    await File(_anchorPath).writeAsString(jsonEncode({
      'version': 1,
      'created': DateTime.now().toIso8601String(),
      'embedding': embedding.toList(),
    }));
    _log.info('Voice anchor enrolled.');
  }

  Future<void> reset() async {
    _anchor = null;
    final f = File(_anchorPath);
    if (f.existsSync()) await f.delete();
  }

  /// Score an interrupting-speech embedding. Returns openMode when
  /// not enrolled (caller must treat as "allow, but flag in UI").
  BargeInVerdict verify(Float32List? embedding) {
    final anchor = _anchor;
    if (anchor == null) return BargeInVerdict.openMode;
    if (embedding == null || embedding.length != anchor.length) {
      return BargeInVerdict.notOwner;
    }
    var dot = 0.0;
    for (var i = 0; i < anchor.length; i++) {
      dot += anchor[i] * embedding[i]; // both L2-normalised → cosine
    }
    _log.debug('Barge-in cosine=${dot.toStringAsFixed(3)} '
        '(threshold=$threshold)');
    return dot >= threshold ? BargeInVerdict.owner : BargeInVerdict.notOwner;
  }
}
