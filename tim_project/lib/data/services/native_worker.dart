// ============================================================
// lib/data/services/native_worker.dart
// Path B — the Python worker, deleted and reborn in-process.
//
// Drop-in replacement for the old WebSocketService: identical public
// surface (`events`, `connect()`, `sendAudio`, `sendJson`,
// `dispose`) and identical event payloads, so chat_provider,
// voice_provider, screen_watcher and video_pipeline keep working
// with a one-line provider swap.
//
// What used to travel over ws://127.0.0.1:8765 now happens as plain
// Dart calls into AudioEngine (sherpa-onnx FFI). Consequences:
//   - no Python install, no venv, no port 8765, no unauthenticated
//     localhost socket leaking mic audio
//   - the "worker offline / reconnect backoff" failure mode is gone
//   - `ready` fires when the models finish loading, not when a
//     socket answers
//
// Pipeline per utterance:
//   mic PCM → VAD segment → [barge-in gate if TTS active]
//     → Whisper STT (word timestamps) → transcription event
//     → speech_analytics event (timing + autocorrelation pitch)
//   tts_request → per-sentence Piper synthesis → ttsChunk events
//     (16 kHz s16le, matching chat_provider's WAV header) → final
//
// Still honest about limits:
//   - screen_vision: no multimodal runtime is bundled yet, so the
//     event returns an explicit "vision not installed" analysis
//     instead of silently pretending (VisionEngine hook provided).
//   - video_pipeline: frame extraction works via bundled ffmpeg.exe
//     when present; the critique text is pacing-only until vision
//     lands.
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/flight_recorder.dart';
import '../../core/utils/logger.dart';
import 'audio_engine.dart';
import 'biometric_gate.dart';
import 'voice_models_catalog.dart';
import 'worker_events.dart';

export 'worker_events.dart';

/// Optional hook for a future multimodal runtime (Moondream2 via a
/// llama.cpp build with mtmd, or an ONNX VLM). Until one is wired,
/// screen vision reports itself as unavailable rather than faking it.
abstract class VisionEngine {
  Future<String> describeImage(Uint8List png, String prompt);
}

class NativeWorker {
  NativeWorker({VisionEngine? vision})
      : _vision = vision,
        _log = Logger('NativeWorker');

  final Logger _log;
  final VisionEngine? _vision;

  final AudioEngine _engine = AudioEngine();
  BiometricGate? _gate;
  VoiceModelsCatalog? _catalog;

  StreamController<WsEvent>? _controller;
  bool _ready = false;
  bool _disposed = false;

  // ---- barge-in / TTS state -------------------------------------
  bool _ttsActive = false;
  bool _speechOpen = false;
  final List<double> _bargeInBuffer = [];
  bool _bargeInPaused = false;

  // ---- screen-vision envelope (contract quirk: JSON header then
  // raw PNG bytes over sendAudio) -------------------------------
  String? _pendingVisionPrompt;

  // ---- enrollment -----------------------------------------------
  bool _enrolling = false;
  final List<double> _enrollBuffer = [];
  static const _enrollSeconds = 10;

  Stream<WsEvent> get events =>
      (_controller ??= StreamController<WsEvent>.broadcast()).stream;

  bool get isReady => _ready;
  bool get voiceLockEnrolled => _gate?.isEnrolled ?? false;

  void _emit(WsEventType t, Map<String, dynamic> payload) {
    if (_disposed) return;
    _controller?.add(WsEvent(t, payload));
  }

  /// Load models and go live. Replaces the old socket connect.
  /// Safe to call repeatedly.
  Future<void> connect() async {
    if (_ready || _disposed) return;
    try {
      final support = await getApplicationSupportDirectory();
      final voiceDir = p.join(support.path, 'voice_models');
      _catalog = VoiceModelsCatalog(baseDir: voiceDir);

      if (!await _catalog!.allInstalled) {
        // No dedicated settings UI exists for this yet, so the worker
        // self-provisions: download the ~180 MB voice bundle on first
        // launch, streaming progress into chat via modelDownload events.
        _emit(WsEventType.modelDownload,
            {'id': 'voice engine', 'pct': 0, 'done': false});
        var lastPct = -1;
        try {
          await _catalog!.ensureAll(onProgress: (id, received, total) {
            if (total <= 0) return;
            final pct = (received * 100 ~/ total);
            if (pct != lastPct && pct % 2 == 0) {
              lastPct = pct;
              _emit(WsEventType.modelDownload, {
                'id': id,
                'pct': pct,
                'received': received,
                'total': total,
                'done': false,
              });
            }
          });
          _emit(WsEventType.modelDownload,
              {'id': 'voice engine', 'pct': 100, 'done': true});
        } catch (e) {
          _emit(WsEventType.error, {
            'message': 'voice_model_download_failed',
            'detail': '$e — check your connection and restart the app '
                'to resume (downloads are resumable).',
          });
          return;
        }
      }

      await _engine.init(_catalog!.resolveEngineConfig());
      _gate = BiometricGate(storageDir: support.path);
      await _gate!.load();

      _ready = true;
      _emit(WsEventType.ready, {
        'engine': 'sherpa-onnx (native FFI)',
        'voice_lock': _gate!.isEnrolled ? 'enrolled' : 'open_mode',
      });
      if (!_gate!.isEnrolled) {
        _emit(WsEventType.biometric,
            {'verified': true, 'mode': 'open', 'enrolled': false},);
      }
    } catch (e, s) {
      _log.warn('connect failed: $e\n$s');
      _emit(WsEventType.error, {'message': '$e'});
    }
  }

  /// One-time voice-model download with progress callbacks
  /// (Settings screen calls this; ~180 MB total).
  Future<void> downloadModels(
      {void Function(String id, int received, int total)? onProgress,}) async {
    final support = await getApplicationSupportDirectory();
    _catalog ??=
        VoiceModelsCatalog(baseDir: p.join(support.path, 'voice_models'));
    await _catalog!.ensureAll(onProgress: onProgress);
    await connect();
  }

  // ================================================================
  // Inbound: audio & binary
  // ================================================================

  /// Same signature as before. Two meanings, per the old contract:
  ///   - normally: 16 kHz mono s16le mic PCM
  ///   - right after a `screen_vision` JSON envelope: raw PNG bytes
  void sendAudio(Uint8List bytes) {
    if (_pendingVisionPrompt != null) {
      final prompt = _pendingVisionPrompt!;
      _pendingVisionPrompt = null;
      unawaited(_runScreenVision(bytes, prompt));
      return;
    }
    if (!_ready) return;
    final samples = AudioEngine.pcm16ToFloat(bytes);

    if (_enrolling) {
      _enrollBuffer.addAll(samples);
      if (_enrollBuffer.length >= AudioEngine.sampleRate * _enrollSeconds) {
        unawaited(_finishEnrollment());
      }
      return;
    }

    // ---- Stage-1 barge-in: speech during TTS pauses playback fast.
    if (_ttsActive) {
      _bargeInBuffer.addAll(samples);
      final speech = _engine.isSpeechActive || _detectEnergy(samples);
      if (speech && !_bargeInPaused) {
        _bargeInPaused = true;
        FlightRecorder.I.log('worker: barge-in stage 1 (pause)');
        _emit(WsEventType.interrupt, {'stage': 1, 'reason': 'speech'});
      }
      if (_bargeInPaused &&
          _bargeInBuffer.length >=
              AudioEngine.sampleRate * BiometricGate.minVerifySeconds) {
        unawaited(_stage2BargeIn());
      }
      // Fall through: the same audio also feeds the VAD so the
      // interrupting utterance is transcribed once confirmed.
    }

    final wasActive = _engine.isSpeechActive;
    final segments = _engine.acceptWaveform(samples);
    final nowActive = _engine.isSpeechActive;

    if (!wasActive && nowActive && !_speechOpen) {
      _speechOpen = true;
      _emit(WsEventType.vad, {'state': 'speech_start'});
    }
    for (final seg in segments) {
      _speechOpen = false;
      _emit(WsEventType.vad, {'state': 'end_of_utterance'});
      // v0.3.8 — while T.I.M.'s own speech may be feeding back into
      // the mic, do NOT transcribe completed segments (T.I.M. was
      // hearing itself through the speakers and replying to itself).
      // Barge-in detection above still runs; after a confirmed owner
      // barge-in, _ttsActive drops and normal transcription resumes.
      if (_selfAudioLikely) {
        FlightRecorder.I.log('worker: utterance dropped (self-audio gate: '
            'tts=$_ttsActive playback=$_clientPlaybackActive)');
        continue;
      }
      unawaited(_handleUtterance(seg));
    }
  }

  bool _detectEnergy(Float32List samples) {
    var e = 0.0;
    for (final v in samples) { e += v * v; }
    return (e / samples.length) > 0.003; // ~-25 dBFS gate
  }

  Future<void> _stage2BargeIn() async {
    final buf = Float32List.fromList(_bargeInBuffer);
    _bargeInBuffer.clear();
    final emb = await _engine.speakerEmbedding(buf);
    final verdict = _gate!.verify(emb);
    FlightRecorder.I.log('worker: barge-in stage 2 verdict=$verdict');
    switch (verdict) {
      case BargeInVerdict.owner:
      case BargeInVerdict.openMode:
        _ttsActive = false; // yield the floor for good
        _ttsRequestQueue.clear();
        _clientPlaybackActive = false;
        _emit(WsEventType.biometric, {
          'verified': true,
          'mode': verdict == BargeInVerdict.openMode ? 'open' : 'biometric',
        });
        // v0.3.9 — this buffer IS the user's interruption. Feeding it
        // to STT (instead of discarding it) is what makes talking
        // over T.I.M. actually work: it stops AND answers what you
        // said, no repeating yourself.
        unawaited(_handleUtterance(buf));
      case BargeInVerdict.notOwner:
        _bargeInPaused = false;
        _emit(WsEventType.biometric, {'verified': false});
      // chat_provider shows "Non-owner voice — barge-in blocked."
      // and playback resumes on the next ttsChunk.
    }
  }

  Future<void> _handleUtterance(Float32List seg) async {
    try {
      final res = await _engine.transcribe(seg);
      if (res.text.isEmpty) return;
      if (_isEchoOfOwnSpeech(res.text)) {
        _log.debug('Dropped echo of own speech: "${res.text}"');
        FlightRecorder.I.log('worker: utterance dropped (echo filter): '
            '"${res.text.length > 40 ? res.text.substring(0, 40) : res.text}"');
        return;
      }
      FlightRecorder.I
          .log('worker: transcribed ${res.text.length} chars \u2192 chat');

      // Owner gate for *initiating* speech: outside of TTS overlap we
      // accept all speech (open conversation), matching old behaviour.
      _emit(WsEventType.transcription, {
        'text': res.text,
        'sender': 'user',
      });

      // Per-word pitch via autocorrelation over each word's window.
      final frames = <Map<String, dynamic>>[];
      for (final w in res.words) {
        final s = (w.startMs * AudioEngine.sampleRate ~/ 1000)
            .clamp(0, seg.length - 1);
        final e =
            (w.endMs * AudioEngine.sampleRate ~/ 1000).clamp(s + 1, seg.length);
        frames.add({
          'word': w.word,
          'start_ms': w.startMs,
          'end_ms': w.endMs,
          'pitch_hz':
              AudioEngine.estimatePitchHz(Float32List.sublistView(seg, s, e)),
        });
      }
      _emit(WsEventType.speechAnalytics, {'frames': frames});
    } catch (e) {
      _log.warn('STT failed: $e');
      _emit(WsEventType.error, {'message': 'stt_failed: $e'});
    }
  }

  /// v0.3.6 — diagnostics: synthesize [phrase] with the TTS voice and
  /// feed the audio straight back into the STT model. Proves the whole
  /// audio ML stack works without touching the mic or speakers.
  Future<String> selfTestVoiceLoop(String phrase) async {
    if (!_ready) throw StateError('Voice engine not initialised');
    final audio = await _engine.synthesize(phrase);
    // Resample to the recognizer's 16 kHz via the existing PCM helpers.
    final pcm = AudioEngine.floatToPcm16(audio.samples, audio.sampleRate);
    final samples = AudioEngine.pcm16ToFloat(pcm);
    final res = await _engine.transcribe(samples);
    return res.text;
  }

  /// v0.3.4 — one-shot dictation for the chat input's mic button
  /// ("its actual purpose is to record the voice … and transfer it
  /// into this text box"). Takes raw mic PCM (16 kHz mono s16le),
  /// returns the transcript. Completely separate from the Live Call
  /// pipeline: no events, no LLM, no TTS.
  Future<String> transcribeOnce(Uint8List pcm16) async {
    if (!_ready) return '';
    final samples = AudioEngine.pcm16ToFloat(pcm16);
    if (samples.length < AudioEngine.sampleRate ~/ 2) return '';
    try {
      final res = await _engine.transcribe(samples);
      return res.text;
    } catch (e) {
      _log.warn('Dictation transcribe failed: $e');
      return '';
    }
  }

  // ================================================================
  // Inbound: JSON control messages (same message types as the old
  // Python worker so callers don't change)
  // ================================================================

  void sendJson(Map<String, dynamic> obj) {
    switch (obj['type'] as String?) {
      case 'tts_request':
        _ttsRequestQueue.add(obj['text'] as String? ?? '');
        unawaited(_drainTtsRequests());
      case 'tts_stop':
        _ttsRequestQueue.clear();
        _ttsActive = false; // breaks the sentence loop in _runTts
      case 'playback_state':
        // v0.3.9 — the CLIENT owns the audio player, so only it knows
        // when speaker output is actually live. This replaces the
        // emission-time heuristic that expired mid-playback and let
        // T.I.M. transcribe its own voice as the user (the duplicated
        // 'Got it. What specifically…' bubbles).
        _clientPlaybackActive = obj['active'] == true;
        FlightRecorder.I
            .log('worker: playback_state=$_clientPlaybackActive');
        if (!_clientPlaybackActive) {
          // v0.4.1 — turn boundary: T.I.M. just finished speaking.
          // Reset every per-turn buffer so turn 2 starts pristine:
          // any VAD residue of our own tail audio, half-accumulated
          // barge-in samples, and the pause flag all go. The mic
          // stream itself stays live — this is state hygiene, not a
          // pipeline teardown.
          _engine.vadReset();
          _bargeInBuffer.clear();
          _bargeInPaused = false;
          _speechOpen = false;
        }
      case 'screen_vision':
        _pendingVisionPrompt = obj['prompt'] as String? ?? '';
      case 'video_pipeline':
        unawaited(_runVideoPipeline(
          obj['path'] as String? ?? '',
          (obj['frame_interval_sec'] as num?)?.toInt() ?? 3,
        ),);
      case 'voice_enroll_start':
        _enrolling = true;
        _enrollBuffer.clear();
      case 'voice_enroll_cancel':
        _enrolling = false;
        _enrollBuffer.clear();
      case 'voice_enroll_reset':
        unawaited(_gate?.reset());
      default:
        _log.debug('Unknown control message: ${obj['type']}');
    }
  }

  // ---- TTS -------------------------------------------------------

  static final _sentenceSplit = RegExp(r'(?<=[.!?])\s+');

  final List<String> _ttsRequestQueue = [];
  bool _ttsDraining = false;
  bool _clientPlaybackActive = false;

  /// v0.4.0 — text-level echo cancellation. Timing gates leak during
  /// the silences BETWEEN spoken sentences (VAD ends utterances right
  /// in those gaps). But the worker knows the EXACT text it spoke, so
  /// any transcript that matches recent speech is provably an echo
  /// and is dropped — regardless of timing, speakers, or volume.
  final List<({String norm, DateTime at})> _recentSpoken = [];

  static String _normalize(String t) =>
      t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  void _rememberSpoken(String text) {
    final n = _normalize(text);
    if (n.isEmpty) return;
    _recentSpoken.add((norm: n, at: DateTime.now()));
    _recentSpoken.removeWhere(
        (e) => DateTime.now().difference(e.at).inSeconds > 90);
    if (_recentSpoken.length > 40) _recentSpoken.removeAt(0);
  }

  bool _isEchoOfOwnSpeech(String transcript) {
    final n = _normalize(transcript);
    if (n.length < 6) return false;
    for (final spoken in _recentSpoken) {
      if (spoken.norm.contains(n)) return true; // transcript ⊆ speech
      // token-overlap fallback (Whisper drops/mangles words)
      final tTokens = n.split(' ').toSet();
      final sTokens = spoken.norm.split(' ').toSet();
      if (tTokens.length >= 4) {
        final overlap = tTokens.intersection(sTokens).length / tTokens.length;
        if (overlap >= 0.8) return true;
      }
    }
    return false;
  }
  DateTime _lastTtsAudioAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// v0.3.8 — per-sentence tts_requests arrive faster than synthesis;
  /// serialize them so audio comes out in order.
  Future<void> _drainTtsRequests() async {
    if (_ttsDraining) return;
    _ttsDraining = true;
    try {
      while (_ttsRequestQueue.isNotEmpty) {
        final text = _ttsRequestQueue.removeAt(0);
        await _runTts(text);
      }
    } finally {
      _ttsDraining = false;
    }
  }

  /// True while T.I.M.'s own speech could be reaching the microphone
  /// (synthesis active, chunks recently emitted, or playback tail).
  bool get _selfAudioLikely =>
      _ttsActive ||
      _clientPlaybackActive ||
      DateTime.now().difference(_lastTtsAudioAt).inMilliseconds < 400;

  Future<void> _runTts(String text) async {
    if (!_ready || text.trim().isEmpty) {
      _emit(WsEventType.ttsChunk, {'pcm': Uint8List(0), 'final': true});
      return;
    }
    _ttsActive = true;
    _bargeInPaused = false;
    _bargeInBuffer.clear();
    try {
      // Sentence-by-sentence synthesis: first audio in ~hundreds of
      // ms instead of waiting for the whole reply.
      for (final sentence in text.split(_sentenceSplit)) {
        if (!_ttsActive) break; // barge-in confirmed mid-reply
        final s = sentence.trim();
        if (s.isEmpty) continue;
        _rememberSpoken(s);
        final audio = await _engine.synthesize(_applyTtsDirectives(s));
        if (!_ttsActive) break;
        final pcm = AudioEngine.floatToPcm16(audio.samples, audio.sampleRate);
        _lastTtsAudioAt = DateTime.now();
        _emit(WsEventType.ttsChunk, {'pcm': pcm, 'final': false});
      }
    } catch (e) {
      _log.warn('TTS failed: $e');
      _emit(WsEventType.error, {'message': 'tts_failed: $e'});
    } finally {
      _emit(WsEventType.ttsChunk, {'pcm': Uint8List(0), 'final': true});
      _ttsActive = false;
    }
  }

  /// Built-in pronunciation directives (kept from the seed):
  /// Q-L-U-E is always spoken as "clue". Extend by reading the
  /// `directives` table (type='tts') from the vault at call sites.
  String _applyTtsDirectives(String s) =>
      s.replaceAll(RegExp('qlue', caseSensitive: false), 'clue');

  // ---- Vision (honest stub with a real hook) ---------------------

  Future<void> _runScreenVision(Uint8List png, String prompt) async {
    if (_vision != null) {
      try {
        final analysis = await _vision?.describeImage(png, prompt);
        _emit(WsEventType.screenVision, {'analysis': analysis});
        return;
      } catch (e) {
        _emit(WsEventType.screenVision,
            {'analysis': '<vision engine error: $e>'},);
        return;
      }
    }
    _emit(WsEventType.screenVision, {
      'analysis': 'Screen vision is not installed in this build yet. '
          'The native vision runtime (Moondream2) is a tracked TODO — '
          'no analysis was produced. (T.I.M. will not pretend it saw '
          'your screen.)',
    });
  }

  // ---- Video pipeline (ffmpeg frame extraction, pacing-only) -----

  Future<void> _runVideoPipeline(String mp4Path, int intervalSec) async {
    try {
      final support = await getApplicationSupportDirectory();
      final ffmpeg = p.join(support.path, 'bin', 'ffmpeg.exe');
      if (!File(ffmpeg).existsSync() || !File(mp4Path).existsSync()) {
        _emit(WsEventType.screenVision, {
          'kind': 'video_summary',
          'frame_count': 0,
          'duration_sec': 0,
          'slide_pace_sec_per_slide': 0,
          'summary': File(mp4Path).existsSync()
              ? '<ffmpeg.exe not bundled — place it in '
                  '${p.join('AppData', 'bin')} or run the setup step>'
              : '<video file not found: $mp4Path>',
        });
        return;
      }
      final outDir = Directory(p.join(support.path, 'video_frames',
          DateTime.now().millisecondsSinceEpoch.toString(),),)
        ..createSync(recursive: true);
      final result = await Process.run(ffmpeg, [
        '-i',
        mp4Path,
        '-vf',
        'fps=1/$intervalSec,scale=640:-1',
        '-q:v',
        '5',
        p.join(outDir.path, 'frame_%04d.jpg'),
        '-hide_banner',
        '-loglevel',
        'error',
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(ffmpeg, const [], '${result.stderr}');
      }
      final frames = outDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .length;
      final durationSec = frames * intervalSec;
      _emit(WsEventType.screenVision, {
        'kind': 'video_summary',
        'frame_count': frames,
        'duration_sec': durationSec,
        'slide_pace_sec_per_slide': frames == 0 ? 0 : durationSec / frames,
        'summary': 'Extracted $frames frames (${intervalSec}s apart). '
            'Visual slide critique pends the vision runtime; pacing '
            'stats are real.',
      });
    } catch (e) {
      _emit(WsEventType.screenVision, {
        'kind': 'video_summary',
        'frame_count': 0,
        'duration_sec': 0,
        'slide_pace_sec_per_slide': 0,
        'summary': '<video pipeline failed: $e>',
      });
    }
  }

  // ---- Enrollment ------------------------------------------------

  Future<void> _finishEnrollment() async {
    _enrolling = false;
    final clip = Float32List.fromList(_enrollBuffer);
    _enrollBuffer.clear();
    if (!_engine.hasSpeakerModel) {
      _emit(WsEventType.biometric, {
        'verified': false,
        'enrolled': false,
        'message': 'Speaker model not installed — Voice Lock unavailable.',
      });
      return;
    }
    // Average embeddings over three ~3.3s windows for a stabler anchor.
    final third = clip.length ~/ 3;
    final embs = <Float32List>[];
    for (var i = 0; i < 3; i++) {
      final e = await _engine.speakerEmbedding(
          Float32List.sublistView(clip, i * third, (i + 1) * third),);
      if (e != null) embs.add(e);
    }
    if (embs.isEmpty) {
      _emit(WsEventType.biometric,
          {'verified': false, 'enrolled': false, 'message': 'Enroll failed'},);
      return;
    }
    final dim = embs.first.length;
    final mean = Float32List(dim);
    for (final e in embs) {
      for (var i = 0; i < dim; i++) { mean[i] += e[i] / embs.length; }
    }
    await _gate!.enroll(mean);
    _emit(WsEventType.biometric,
        {'verified': true, 'enrolled': true, 'mode': 'biometric'},);
  }

  void dispose() {
    _disposed = true;
    _engine.dispose();
    _controller?.close();
  }
}
