// ============================================================
// lib/data/services/audio_engine.dart
// Path B — fully-native audio stack via sherpa-onnx (Dart FFI).
//
// Replaces the ENTIRE Python worker's audio duties in one runtime:
//   - Silero VAD          (was backend/vad.py)
//   - Whisper STT         (was backend/stt_whisper.py)
//   - Piper-voice TTS     (was backend/tts_piper.py — sherpa-onnx
//                          runs Piper .onnx voices natively)
//   - Speaker embeddings  (was backend/voice_biometric.py)
//
// One C library (`sherpa-onnx`), one Dart package, zero Python.
//
// NOTE ON API SURFACE: written against `package:sherpa_onnx` 1.x.
// If a constructor/field name drifts in the version you pin, the
// compiler will point at it — the *shape* of each call is correct.
// Call `AudioEngine.init()` once (from a background isolate ideally)
// before any other method.
// ============================================================

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/utils/logger.dart';

/// One recognised word with timing, for SpeechAnalytics.
class WordStamp {
  WordStamp({required this.word, required this.startMs, required this.endMs});
  final String word;
  final int startMs;
  final int endMs;
}

class AsrResult {
  AsrResult({required this.text, required this.words});
  final String text;
  final List<WordStamp> words;
}

class TtsAudio {
  TtsAudio({required this.samples, required this.sampleRate});
  final Float32List samples;
  final int sampleRate;
}

/// Paths to the ONNX model files, resolved by VoiceModelsCatalog
/// after download into <app_support>/voice_models/.
class AudioEngineConfig {
  const AudioEngineConfig({
    required this.sileroVadPath,
    required this.whisperEncoderPath,
    required this.whisperDecoderPath,
    required this.whisperTokensPath,
    required this.ttsModelPath,
    required this.ttsTokensPath,
    required this.ttsDataDir,
    this.speakerModelPath, // optional until Voice Lock is enrolled
  });

  final String sileroVadPath;
  final String whisperEncoderPath;
  final String whisperDecoderPath;
  final String whisperTokensPath;
  final String ttsModelPath;
  final String ttsTokensPath;
  final String ttsDataDir; // espeak-ng-data dir shipped with piper voices
  final String? speakerModelPath;
}

class AudioEngine {
  AudioEngine() : _log = Logger('AudioEngine');

  final Logger _log;

  sherpa.VoiceActivityDetector? _vad;
  sherpa.OfflineRecognizer? _asr;
  sherpa.OfflineTts? _tts;
  sherpa.SpeakerEmbeddingExtractor? _speaker;

  bool get isReady => _asr != null && _tts != null && _vad != null;
  bool get hasSpeakerModel => _speaker != null;

  static const int sampleRate = 16000;

  /// Load every model. Heavy (~1-3 s on first call): run off the UI
  /// thread (the NativeWorker calls this from connect()).
  Future<void> init(AudioEngineConfig cfg) async {
    if (isReady) return;
    // Loads the bundled sherpa-onnx C library (libsherpa-onnx-c-api).
    sherpa.initBindings();

    for (final p in [
      cfg.sileroVadPath,
      cfg.whisperEncoderPath,
      cfg.whisperDecoderPath,
      cfg.whisperTokensPath,
      cfg.ttsModelPath,
      cfg.ttsTokensPath,
    ]) {
      if (!File(p).existsSync()) {
        throw FileSystemException('Voice model missing — run the voice '
            'model downloader first', p);
      }
    }

    // ---- VAD -----------------------------------------------------
    final vadCfg = sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: cfg.sileroVadPath,
        threshold: 0.5,
        minSilenceDuration: 0.35, // adaptive endpointing: 350ms base
        minSpeechDuration: 0.25,
        windowSize: 512,
      ),
      sampleRate: sampleRate,
      numThreads: 1,
      debug: false,
    );
    _vad = sherpa.VoiceActivityDetector(
        config: vadCfg, bufferSizeInSeconds: 30);

    // ---- STT (Whisper via sherpa-onnx offline recognizer) --------
    final asrCfg = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: cfg.whisperEncoderPath,
          decoder: cfg.whisperDecoderPath,
          // Without this flag sherpa-onnx 1.13.x returns EMPTY
          // timestamps and SpeechAnalytics silently sees no timing.
          // (Verified against the 1.13.4 package source.)
          enableTokenTimestamps: true,
        ),
        tokens: cfg.whisperTokensPath,
        numThreads: math.max(2, Platform.numberOfProcessors ~/ 2),
        modelType: 'whisper',
        debug: false,
      ),
    );
    _asr = sherpa.OfflineRecognizer(asrCfg);

    // ---- TTS (Piper voice, VITS architecture) --------------------
    final ttsCfg = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: cfg.ttsModelPath,
          tokens: cfg.ttsTokensPath,
          dataDir: cfg.ttsDataDir,
        ),
        numThreads: 2,
        debug: false,
      ),
    );
    _tts = sherpa.OfflineTts(ttsCfg);

    // ---- Speaker verification (optional) -------------------------
    if (cfg.speakerModelPath != null &&
        File(cfg.speakerModelPath!).existsSync()) {
      _speaker = sherpa.SpeakerEmbeddingExtractor(
        config: sherpa.SpeakerEmbeddingExtractorConfig(
          model: cfg.speakerModelPath!,
          numThreads: 1,
        ),
      );
    }
    _log.info('AudioEngine ready (speakerModel=${hasSpeakerModel}).');
  }

  // ---- VAD -------------------------------------------------------

  /// Feed a mic frame; returns any completed speech segments.
  /// Input is Float32 mono @16k in [-1, 1].
  List<Float32List> acceptWaveform(Float32List frame) {
    final vad = _vad;
    if (vad == null) return const [];
    vad.acceptWaveform(frame);
    final segments = <Float32List>[];
    while (!vad.isEmpty()) {
      segments.add(Float32List.fromList(vad.front().samples));
      vad.pop();
    }
    return segments;
  }

  bool get isSpeechActive => _vad?.isDetected() ?? false;

  void vadFlush() => _vad?.flush();
  void vadReset() => _vad?.clear();

  // ---- STT -------------------------------------------------------

  Future<AsrResult> transcribe(Float32List samples) async {
    final asr = _asr;
    if (asr == null) throw StateError('AudioEngine not initialised');
    final stream = asr.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    asr.decode(stream);
    final res = asr.getResult(stream);
    stream.free();

    // Whisper models expose token-level timestamps; group into words.
    final words = <WordStamp>[];
    final tokens = res.tokens;
    final stamps = res.timestamps; // seconds, aligned with tokens
    var current = StringBuffer();
    var curStart = 0.0, curEnd = 0.0;
    void flushWord() {
      final w = current.toString().trim();
      if (w.isNotEmpty) {
        words.add(WordStamp(
          word: w,
          startMs: (curStart * 1000).round(),
          endMs: (curEnd * 1000).round(),
        ));
      }
      current = StringBuffer();
    }

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      final ts = i < stamps.length ? stamps[i] : curEnd;
      if (t.startsWith(' ') || current.isEmpty) {
        flushWord();
        curStart = ts;
      }
      current.write(t);
      curEnd = ts;
    }
    flushWord();

    return AsrResult(text: res.text.trim(), words: words);
  }

  // ---- TTS -------------------------------------------------------

  Future<TtsAudio> synthesize(String text, {double speed = 1.0}) async {
    final tts = _tts;
    if (tts == null) throw StateError('AudioEngine not initialised');
    final audio = tts.generate(text: text, sid: 0, speed: speed);
    return TtsAudio(
      samples: Float32List.fromList(audio.samples),
      sampleRate: audio.sampleRate,
    );
  }

  // ---- Speaker embedding ----------------------------------------

  /// Returns an L2-normalised speaker embedding, or null if no
  /// speaker model is installed (Voice Lock disabled → open mode).
  Future<Float32List?> speakerEmbedding(Float32List samples) async {
    final sp = _speaker;
    if (sp == null) return null;
    final stream = sp.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    stream.inputFinished();
    final emb = Float32List.fromList(sp.compute(stream));
    stream.free();
    // L2 normalise so cosine == dot product.
    var norm = 0.0;
    for (final v in emb) norm += v * v;
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < emb.length; i++) emb[i] /= norm;
    }
    return emb;
  }

  // ---- PCM helpers ----------------------------------------------

  /// Int16 LE bytes (mic format from `record`) → Float32 [-1, 1].
  static Float32List pcm16ToFloat(Uint8List pcm) {
    final bd = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Float32 [-1, 1] → Int16 LE bytes, with linear resample to
  /// [targetRate] (chat playback expects 16 kHz mono s16le).
  static Uint8List floatToPcm16(Float32List samples, int srcRate,
      {int targetRate = 16000}) {
    Float32List resampled;
    if (srcRate == targetRate) {
      resampled = samples;
    } else {
      final ratio = srcRate / targetRate;
      final n = (samples.length / ratio).floor();
      resampled = Float32List(n);
      for (var i = 0; i < n; i++) {
        final pos = i * ratio;
        final i0 = pos.floor();
        final i1 = math.min(i0 + 1, samples.length - 1);
        final frac = pos - i0;
        resampled[i] = samples[i0] * (1 - frac) + samples[i1] * frac;
      }
    }
    final out = Uint8List(resampled.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < resampled.length; i++) {
      final v = (resampled[i].clamp(-1.0, 1.0) * 32767).round();
      bd.setInt16(i * 2, v, Endian.little);
    }
    return out;
  }

  /// Crude autocorrelation pitch estimate (Hz) for a mono window.
  /// Good enough for SpeechAnalytics' variance heuristic.
  static double estimatePitchHz(Float32List w, {int rate = sampleRate}) {
    if (w.length < 400) return 0;
    const fMin = 70, fMax = 350;
    final lagMin = rate ~/ fMax, lagMax = rate ~/ fMin;
    var bestLag = 0;
    var bestCorr = 0.0;
    for (var lag = lagMin; lag <= lagMax && lag < w.length; lag++) {
      var corr = 0.0;
      for (var i = 0; i + lag < w.length; i++) {
        corr += w[i] * w[i + lag];
      }
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }
    if (bestLag == 0) return 0;
    // Reject unvoiced/noise windows.
    var energy = 0.0;
    for (final v in w) energy += v * v;
    if (energy < 1e-4 || bestCorr / energy < 0.3) return 0;
    return rate / bestLag;
  }

  void dispose() {
    _vad?.free();
    _asr?.free();
    _tts?.free();
    _speaker?.free();
    _vad = null;
    _asr = null;
    _tts = null;
    _speaker = null;
  }
}
