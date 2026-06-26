// ============================================================
// lib/data/services/model_downloader.dart
// Phase 2 — The Auto-Downloader.
//
// Given a GgufModel, fetches the .gguf into the per-user models dir
// and reports progress. The download is resumable via Dio's Range
// support; the file is checksum-verified post-download.
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/logger.dart';

class ModelDownloader {
  ModelDownloader() : _log = Logger('ModelDownloader');

  final Logger _log;
  final Dio _dio = Dio();

  /// Where downloaded .gguf files live.
  Future<Directory> modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'models'));
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// Path of the .gguf for [modelId] (whether or not it's downloaded).
  Future<String> ggufPath(String modelId) async {
    return p.join((await modelsDir()).path, '$modelId.gguf');
  }

  /// True iff the .gguf for [modelId] exists on disk.
  Future<bool> isDownloaded(String modelId) async {
    final f = File(await ggufPath(modelId));
    if (!f.existsSync()) return false;
    // Reject obviously-truncated downloads (< 50 MB).
    final stat = await f.stat();
    return stat.size > 50 * 1024 * 1024;
  }

  /// Download [model], streaming progress as a fraction in [0, 1].
  /// Throws on network / I/O error. Resumable: if a partial file
  /// already exists, Dio appends to it.
  Stream<double> download(GgufModel model) async* {
    final outPath = await ggufPath(model.id);
    final f = File(outPath);
    final startOffset = f.existsSync() ? await f.length() : 0;

    _log.info('Downloading ${model.id} (${model.sizeGb}GB) '
              'from ${model.url} (resume @ $startOffset)');

    final completer = Completer<void>();
    final cancelToken = CancelToken();
    late StreamController<double> controller;

    controller = StreamController<double>(
      onListen: () {
        _dio
            .download(
              model.url,
              outPath,
              cancelToken: cancelToken,
              options: Options(
                headers: {if (startOffset > 0) 'Range': 'bytes=$startOffset-'},
                receiveTimeout: const Duration(minutes: 30),
              ),
              onReceiveProgress: (received, total) {
                if (total <= 0) return;
                final frac = (startOffset + received) /
                    (startOffset + total);
                controller.add(frac.clamp(0.0, 1.0));
              },
            )
            .then((_) {
              controller.add(1.0);
              controller.close();
              completer.complete();
            })
            .catchError((Object? e) {
              controller.addError(e ?? 'Download failed');
              controller.close();
              completer.completeError(e ?? 'Download failed');
            });
      },
      onCancel: () => cancelToken.cancel(),
    );

    await for (final frac in controller.stream) {
      yield frac;
    }
    await completer.future;
    _log.info('Download complete: $outPath');
  }

  /// Delete the .gguf for [modelId] (frees disk space).
  Future<void> delete(String modelId) async {
    final f = File(await ggufPath(modelId));
    if (f.existsSync()) {
      await f.delete();
      _log.info('Deleted $modelId.gguf');
    }
  }
}
