// ============================================================
// lib/data/services/voice_models_catalog.dart
// Path B — download manifest for the sherpa-onnx voice models.
//
// Mirrors what ModelDownloader does for .gguf weights, but for the
// ONNX voice stack. All assets come from the k2-fsa/sherpa-onnx
// GitHub release pages (stable, free, permissively licensed).
//
// ⚠ VERIFY-BEFORE-SHIP: the URLs below follow sherpa-onnx's
// long-standing release naming, but release assets can move.
// `flutter test test/voice_models_urls_test.dart` (added by this
// patch) HEAD-checks every URL so CI catches drift.
//
// Integrity: first successful download computes SHA-256 and pins it
// to models.lock.json (trust-on-first-use). Subsequent downloads or
// re-verification must match the pinned digest.
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import 'audio_engine.dart';

class VoiceModelSpec {
  const VoiceModelSpec({
    required this.id,
    required this.url,
    required this.archive, // 'tar.bz2' | 'none'
    required this.approxMb,
  });
  final String id;
  final String url;
  final String archive;
  final int approxMb;
}

class VoiceModelsCatalog {
  VoiceModelsCatalog({required this.baseDir, Dio? dio})
      : _dio = dio ?? Dio(),
        _log = Logger('VoiceModelsCatalog');

  /// <app_support>/voice_models
  final String baseDir;
  final Dio _dio;
  final Logger _log;

  static const _gh =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download';

  /// ~180 MB total — an order of magnitude smaller than the Python
  /// worker's pip footprint (torch alone was >2 GB).
  static const specs = <VoiceModelSpec>[
    // Silero VAD (single .onnx file)
    VoiceModelSpec(
      id: 'silero_vad',
      url: '$_gh/asr-models/silero_vad.onnx',
      archive: 'none',
      approxMb: 2,
    ),
    // Whisper tiny.en (int8) — encoder/decoder/tokens in one tarball
    VoiceModelSpec(
      id: 'sherpa-onnx-whisper-tiny.en',
      url: '$_gh/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2',
      archive: 'tar.bz2',
      approxMb: 110,
    ),
    // Piper voice (Amy, low = native 16 kHz → no resample on playback)
    VoiceModelSpec(
      id: 'vits-piper-en_US-amy-low',
      url: '$_gh/tts-models/vits-piper-en_US-amy-low.tar.bz2',
      archive: 'tar.bz2',
      approxMb: 65,
    ),
    // Speaker verification (3D-Speaker ERes2Net) for Voice Lock.
    // NOTE: the release tag is genuinely spelled "recongition"
    // upstream — do not "fix" it.
    VoiceModelSpec(
      id: '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k',
      url: '$_gh/speaker-recongition-models/'
          '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
      archive: 'none',
      approxMb: 26,
    ),
  ];

  String get _lockPath => p.join(baseDir, 'models.lock.json');

  Future<bool> get allInstalled async {
    try {
      resolveEngineConfig();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Download + extract everything that's missing.
  /// [onProgress] receives (modelId, received, total).
  Future<void> ensureAll(
      {void Function(String id, int received, int total)? onProgress}) async {
    await Directory(baseDir).create(recursive: true);
    final lock = _readLock();

    for (final spec in specs) {
      final marker = File(p.join(baseDir, '.${spec.id}.ok'));
      if (marker.existsSync()) continue;

      final dlPath = p.join(baseDir, p.basename(spec.url));
      _log.info('Downloading ${spec.id} (~${spec.approxMb} MB)…');
      await _dio.download(
        spec.url,
        dlPath,
        // dio resumes automatically when deleteOnError=false + Range
        // is supported by GitHub's CDN.
        deleteOnError: false,
        onReceiveProgress: (r, t) => onProgress?.call(spec.id, r, t),
      );

      // ---- integrity: TOFU SHA-256 pin ---------------------------
      final digest =
          (await sha256.bind(File(dlPath).openRead()).first).toString();
      final pinned = lock[spec.id] as String?;
      if (pinned == null) {
        lock[spec.id] = digest;
        _log.info('${spec.id}: pinned sha256=$digest');
      } else if (pinned != digest) {
        await File(dlPath).delete();
        throw StateError('${spec.id}: sha256 mismatch — expected $pinned, '
            'got $digest. Refusing to install.');
      }

      // ---- extract ----------------------------------------------
      if (spec.archive == 'tar.bz2') {
        final bytes = await File(dlPath).readAsBytes();
        final tar = BZip2Decoder().decodeBytes(bytes);
        final files = TarDecoder().decodeBytes(tar);
        for (final f in files) {
          final out = p.normalize(p.join(baseDir, f.name));
          if (!p.isWithin(baseDir, out)) continue; // zip-slip guard
          if (f.isFile) {
            final file = File(out)..createSync(recursive: true);
            file.writeAsBytesSync(f.content as List<int>);
          }
        }
        await File(dlPath).delete();
      }
      marker.writeAsStringSync(DateTime.now().toIso8601String());
    }
    _writeLock(lock);
    _log.info('All voice models installed.');
  }

  /// Build the AudioEngineConfig from installed files.
  /// Throws FileSystemException naming the first missing piece.
  AudioEngineConfig resolveEngineConfig() {
    final whisperDir = p.join(baseDir, 'sherpa-onnx-whisper-tiny.en');
    final piperDir = p.join(baseDir, 'vits-piper-en_US-amy-low');
    String req(String path) {
      if (!File(path).existsSync()) {
        throw FileSystemException('voice model file missing', path);
      }
      return path;
    }

    final speakerPath = p.join(baseDir,
        '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx');

    return AudioEngineConfig(
      sileroVadPath: req(p.join(baseDir, 'silero_vad.onnx')),
      whisperEncoderPath:
          req(p.join(whisperDir, 'tiny.en-encoder.int8.onnx')),
      whisperDecoderPath:
          req(p.join(whisperDir, 'tiny.en-decoder.int8.onnx')),
      whisperTokensPath: req(p.join(whisperDir, 'tiny.en-tokens.txt')),
      ttsModelPath: req(p.join(piperDir, 'en_US-amy-low.onnx')),
      ttsTokensPath: req(p.join(piperDir, 'tokens.txt')),
      ttsDataDir: p.join(piperDir, 'espeak-ng-data'),
      speakerModelPath:
          File(speakerPath).existsSync() ? speakerPath : null,
    );
  }

  Map<String, dynamic> _readLock() {
    final f = File(_lockPath);
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void _writeLock(Map<String, dynamic> lock) =>
      File(_lockPath).writeAsStringSync(jsonEncode(lock));
}
