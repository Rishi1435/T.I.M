// ============================================================
// lib/data/services/model_downloader.dart
// Phase 2 — The Auto-Downloader (Parallel Chunk Edition).
//
// Strategy: split the remote file into N equal chunks and
// download them simultaneously with N independent Dio connections.
// Each chunk is written to a temp file then merged in order.
// This saturates the full pipe on any broadband link, just like
// IDM / aria2c, because most CDNs (incl. HuggingFace) throttle
// per connection.
//
// Features:
//   - 8 parallel connections by default (saturates bandwidth)
//   - Resumable: existing chunk temp files are reused
//   - Speed (MB/s) + ETA reported on every progress tick
//   - Falls back to single-connection if server doesn't accept Range
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/logger.dart';

/// Progress snapshot emitted on every tick.
class DownloadProgress {
  const DownloadProgress({
    required this.fraction,
    required this.bytesReceived,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.etaSeconds,
  });

  /// 0.0 – 1.0
  final double fraction;
  final int bytesReceived;
  final int totalBytes;

  /// Current download speed in bytes per second.
  final double speedBytesPerSec;

  /// Estimated seconds remaining (-1 if unknown).
  final int etaSeconds;

  String get speedLabel {
    if (speedBytesPerSec <= 0) return '—';
    final mb = speedBytesPerSec / (1024 * 1024);
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
    final kb = speedBytesPerSec / 1024;
    return '${kb.toStringAsFixed(0)} KB/s';
  }

  String get etaLabel {
    if (etaSeconds < 0) return '—';
    if (etaSeconds < 60) return '${etaSeconds}s';
    if (etaSeconds < 3600) {
      final m = etaSeconds ~/ 60;
      final s = etaSeconds % 60;
      return '${m}m ${s}s';
    }
    final h = etaSeconds ~/ 3600;
    final m = (etaSeconds % 3600) ~/ 60;
    return '${h}h ${m}m';
  }

  String get receivedLabel {
    final mb = bytesReceived / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  String get totalLabel {
    final mb = totalBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }
}

/// Thrown when the user pauses the download (via cancelAll()).
/// NOT an error \u2014 the controller catches this and sets phase=paused.
class DownloadPausedException implements Exception {
  const DownloadPausedException();
  @override
  String toString() => 'DownloadPausedException';
}

class ModelDownloader {
  ModelDownloader() : _log = Logger('ModelDownloader');

  final Logger _log;

  /// All active Dio CancelTokens (one per chunk + one for HEAD probe).
  /// Call cancelAll() to pause — chunk .tmp files are preserved on disk
  /// so the next download() call will resume from each chunk's offset.
  final List<CancelToken> _activeCancelTokens = [];

  /// Cancel every active connection (pause). Safe to call from any isolate.
  void cancelAll() {
    for (final t in _activeCancelTokens) {
      if (!t.isCancelled) t.cancel('paused');
    }
    _activeCancelTokens.clear();
    _log.info('All download connections cancelled (paused).');
  }

  /// Number of parallel download connections.
  static const int _parallelChunks = 8;

  /// Minimum chunk size: 16 MB (don't split tiny files).
  static const int _minChunkBytes = 16 * 1024 * 1024;

  Dio _makeDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 60),
          responseType: ResponseType.stream,
        ),
      );

  // ---- directory helpers ----------------------------------------

  Future<Directory> modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'models'));
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  Future<String> ggufPath(String modelId) async =>
      p.join((await modelsDir()).path, '$modelId.gguf');

  Future<bool> isDownloaded(String modelId) async {
    final f = File(await ggufPath(modelId));
    if (!f.existsSync()) return false;
    final stat = await f.stat();
    return stat.size > 50 * 1024 * 1024;
  }

  /// Download [model], yielding [DownloadProgress] on every tick.
  /// Uses parallel chunked connections for maximum speed.
  /// When paused via cancelAll(), throws a [DownloadPausedException].
  Stream<DownloadProgress> download(GgufModel model) async* {
    final outPath = await ggufPath(model.id);
    _log.info('Starting download: ${model.id} (${model.sizeGb} GB)');

    // ------ Step 1: probe remote content-length & Range support ----
    final headToken = CancelToken();
    _activeCancelTokens.add(headToken);
    final dio = _makeDio();
    late int totalBytes;
    late bool supportsRange;

    try {
      final head = await dio.head(
        model.url,
        cancelToken: headToken,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          followRedirects: true,
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      _activeCancelTokens.remove(headToken);
      supportsRange = head.statusCode == 206;
      final cl = head.headers.value('content-length');
      final cr = head.headers.value('content-range');

      if (supportsRange && cr != null) {
        totalBytes = int.tryParse(cr.split('/').last.trim()) ?? 0;
      } else if (cl != null) {
        totalBytes = int.tryParse(cl) ?? 0;
      } else {
        totalBytes = (model.sizeGb * 1024 * 1024 * 1024).round();
      }
    } on DioException catch (e) {
      _activeCancelTokens.remove(headToken);
      if (CancelToken.isCancel(e)) throw const DownloadPausedException();
      supportsRange = false;
      totalBytes = (model.sizeGb * 1024 * 1024 * 1024).round();
    } catch (_) {
      _activeCancelTokens.remove(headToken);
      supportsRange = false;
      totalBytes = (model.sizeGb * 1024 * 1024 * 1024).round();
    }

    _log.info('Remote size: ${totalBytes ~/ (1024 * 1024)} MB, '
        'rangeSupport=$supportsRange');

    // ------ Step 2: choose strategy ----------------------------
    if (!supportsRange || totalBytes < _minChunkBytes * 2) {
      yield* _singleConnectionDownload(model, outPath, totalBytes);
      return;
    }

    // ------ Step 3: parallel chunked download ------------------
    yield* _parallelDownload(model, outPath, totalBytes);
  }

  // ---- single-connection fallback ------------------------------

  Stream<DownloadProgress> _singleConnectionDownload(
    GgufModel model,
    String outPath,
    int totalBytes,
  ) async* {
    final f = File(outPath);
    final startOffset = f.existsSync() ? await f.length() : 0;
    final dio = _makeDio();
    final cancelToken = CancelToken();
    _activeCancelTokens.add(cancelToken);

    final progressCtrl = StreamController<DownloadProgress>();
    int received = startOffset;
    final startTime = DateTime.now();

    unawaited(
      dio
          .download(
            model.url,
            outPath,
            cancelToken: cancelToken,
            options: Options(
              headers: {
                if (startOffset > 0) 'Range': 'bytes=$startOffset-',
              },
              receiveTimeout: const Duration(minutes: 60),
            ),
            onReceiveProgress: (got, total) {
              received = startOffset + got;
              final elapsedSec =
                  DateTime.now().difference(startTime).inMilliseconds / 1000.0;
              final speed =
                  elapsedSec > 0 ? (received - startOffset) / elapsedSec : 0;
              final remaining = totalBytes - received;
              final eta = speed > 0 ? (remaining / speed).round() : -1;

              if (!progressCtrl.isClosed) {
                progressCtrl.add(
                  DownloadProgress(
                    fraction: (received / totalBytes).clamp(0.0, 1.0),
                    bytesReceived: received,
                    totalBytes: totalBytes,
                    speedBytesPerSec: speed.toDouble(),
                    etaSeconds: eta,
                  ),
                );
              }
            },
          )
          .then((_) {
            _activeCancelTokens.remove(cancelToken);
            if (!progressCtrl.isClosed) progressCtrl.close();
          })
          .catchError((Object e) {
            _activeCancelTokens.remove(cancelToken);
            if (!progressCtrl.isClosed) {
              if (e is DioException && CancelToken.isCancel(e)) {
                progressCtrl.addError(const DownloadPausedException());
              } else {
                progressCtrl.addError(e);
              }
              progressCtrl.close();
            }
          }),
    );

    await for (final prog in progressCtrl.stream) {
      yield prog;
    }
  }

  // ---- parallel chunked download --------------------------------

  Stream<DownloadProgress> _parallelDownload(
    GgufModel model,
    String outPath,
    int totalBytes,
  ) async* {
    final dir = (await modelsDir()).path;
    final chunkCount = math.min(
      _parallelChunks,
      (totalBytes / _minChunkBytes).ceil(),
    );
    final chunkSize = (totalBytes / chunkCount).ceil();

    _log.info('Parallel download: $chunkCount chunks × '
        '${chunkSize ~/ (1024 * 1024)} MB each');

    // Build chunk descriptors.
    final chunks = List.generate(chunkCount, (i) {
      final start = i * chunkSize;
      final end = math.min(start + chunkSize - 1, totalBytes - 1);
      final tmpPath = p.join(dir, '${model.id}.chunk$i.tmp');
      return _Chunk(index: i, start: start, end: end, tmpPath: tmpPath);
    });

    // Shared progress counters (one per chunk).
    final chunkReceived = List<int>.filled(chunkCount, 0);

    // Pre-fill from existing temp files (resumable chunks).
    for (final c in chunks) {
      final f = File(c.tmpPath);
      if (f.existsSync()) {
        chunkReceived[c.index] = await f.length();
      }
    }

    // Progress broadcast.
    final progressCtrl = StreamController<DownloadProgress>.broadcast();
    final startTime = DateTime.now();
    int lastTotalReceived = chunkReceived.fold(0, (a, b) => a + b);

    // Speed smoother: rolling 2-second window.
    final speedSamples = <_SpeedSample>[];
    var lastEmitMs = 0.0;

    void emitProgress({bool force = false}) {
      final elapsedMs =
          DateTime.now().difference(startTime).inMilliseconds.toDouble();

      // Throttle progress updates to at most once every 150ms, unless forced (e.g. completion).
      if (!force && elapsedMs - lastEmitMs < 150) {
        return;
      }
      lastEmitMs = elapsedMs;

      final totalReceived = chunkReceived.fold<int>(0, (a, b) => a + b);

      // Collect speed sample.
      speedSamples.add(
        _SpeedSample(
          bytes: totalReceived,
          timestampMs: elapsedMs,
        ),
      );
      // Keep only last 2 seconds.
      speedSamples.removeWhere(
        (s) => elapsedMs - s.timestampMs > 2000,
      );

      double speed = 0;
      if (speedSamples.length >= 2) {
        final oldest = speedSamples.first;
        final newest = speedSamples.last;
        final dt = (newest.timestampMs - oldest.timestampMs) / 1000.0;
        if (dt > 0) {
          speed = (newest.bytes - oldest.bytes) / dt;
        }
      } else if (elapsedMs > 0) {
        speed = (totalReceived - lastTotalReceived) / (elapsedMs / 1000.0);
      }

      final remaining = totalBytes - totalReceived;
      final eta = speed > 0 ? (remaining / speed).round() : -1;

      if (!progressCtrl.isClosed) {
        progressCtrl.add(
          DownloadProgress(
            fraction: (totalReceived / totalBytes).clamp(0.0, 1.0),
            bytesReceived: totalReceived,
            totalBytes: totalBytes,
            speedBytesPerSec: speed,
            etaSeconds: eta,
          ),
        );
      }
      lastTotalReceived = totalReceived;
    }

    // Launch all chunk downloads in parallel.
    final cancelTokens = List.generate(chunkCount, (_) => CancelToken());
    _activeCancelTokens.addAll(cancelTokens);

    final futures = List.generate(chunkCount, (i) {
      final c = chunks[i];
      final ct = cancelTokens[i];
      return _downloadChunk(
        url: model.url,
        chunk: c,
        cancelToken: ct,
        onProgress: (got) {
          chunkReceived[c.index] = got;
          emitProgress();
        },
      );
    });

    final errorCompleter = Completer<void>();
    var completed = 0;

    for (int i = 0; i < chunkCount; i++) {
      final fut = futures[i];
      final ct = cancelTokens[i];
      fut.then((_) {
        _activeCancelTokens.remove(ct);
        completed++;
        if (completed == chunkCount && !progressCtrl.isClosed) {
          emitProgress(force: true); // Emit final/100% progress
          progressCtrl.close();
        }
      }).catchError((Object e) {
        _activeCancelTokens.remove(ct);
        // Cancel all other sibling chunk downloads to save resources
        for (final token in cancelTokens) {
          if (!token.isCancelled) {
            token.cancel('paused');
          }
        }
        if (!errorCompleter.isCompleted) {
          if (e is DioException && CancelToken.isCancel(e)) {
            const pausedEx = DownloadPausedException();
            errorCompleter.completeError(pausedEx);
            progressCtrl.addError(pausedEx);
          } else {
            errorCompleter.completeError(e);
            progressCtrl.addError(e);
          }
          progressCtrl.close();
        }
      });
    }

    await for (final prog in progressCtrl.stream) {
      yield prog;
    }

    if (errorCompleter.isCompleted) {
      await errorCompleter.future; // rethrow
    }

    // ------ Step 4: merge chunks into final file ----------------
    _log.info('All chunks done — merging into $outPath');
    final out = File(outPath).openWrite();
    for (final c in chunks) {
      final tmp = File(c.tmpPath);
      await out.addStream(tmp.openRead());
    }
    await out.close();
    _log.info('Merge complete: $outPath');

    // Cleanup temp files.
    for (final c in chunks) {
      try {
        await File(c.tmpPath).delete();
      } catch (_) {}
    }
  }

  // ---- chunk worker --------------------------------------------

  Future<void> _downloadChunk({
    required String url,
    required _Chunk chunk,
    required CancelToken cancelToken,
    required void Function(int bytesGot) onProgress,
  }) async {
    final f = File(chunk.tmpPath);
    final startOffset = f.existsSync() ? await f.length() : 0;
    final chunkTotal = chunk.end - chunk.start + 1;

    if (startOffset >= chunkTotal) {
      // Already complete.
      onProgress(chunkTotal);
      return;
    }

    final rangeStart = chunk.start + startOffset;
    final dio = _makeDio();

    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=$rangeStart-${chunk.end}'},
          receiveTimeout: const Duration(minutes: 60),
        ),
      );

      final raf = await f.open(mode: FileMode.writeOnlyAppend);
      int got = startOffset;
      int lastNotified = startOffset;

      await for (final bytes in (response.data as ResponseBody).stream) {
        if (cancelToken.isCancelled) {
          await raf.close();
          throw DioException(
            requestOptions: response.requestOptions,
            error: 'paused',
            type: DioExceptionType.cancel,
          );
        }
        await raf.writeFrom(bytes);
        got += bytes.length;
        // Throttle progress updates to avoid flooding event loop
        if (got - lastNotified > 128 * 1024) {
          onProgress(got);
          lastNotified = got;
        }
      }
      await raf.close();
      onProgress(got); // final notification
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _log.info('Chunk ${chunk.index} download cancelled/paused.');
      } else {
        _log.warn('Chunk ${chunk.index} failed: $e — will retry on next run.');
      }
      rethrow;
    }
  }

  // ---- delete ---------------------------------------------------

  Future<void> delete(String modelId) async {
    final f = File(await ggufPath(modelId));
    if (f.existsSync()) {
      await f.delete();
      _log.info('Deleted $modelId.gguf');
    }
    // Also clean up any orphan chunk temp files.
    final dir = await modelsDir();
    for (final entity in dir.listSync()) {
      if (entity.path.contains('$modelId.chunk') &&
          entity.path.endsWith('.tmp')) {
        await entity.delete();
      }
    }
  }
}

// ---- internal helpers -----------------------------------------

class _Chunk {
  const _Chunk({
    required this.index,
    required this.start,
    required this.end,
    required this.tmpPath,
  });
  final int index;
  final int start;
  final int end;
  final String tmpPath;
}

class _SpeedSample {
  const _SpeedSample({required this.bytes, required this.timestampMs});
  final int bytes;
  final double timestampMs;
}
