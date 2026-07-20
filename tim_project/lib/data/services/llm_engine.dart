// ============================================================
// lib/data/services/llm_engine.dart
// Native LLM inference via llama_cpp_dart (Dart FFI to llama.cpp).
//
// T.I.M. runs the model IN-PROCESS — no Python, no Ollama, no
// terminal. The .gguf file is fetched by ModelDownloader and stored
// under <app_support_dir>/models/<id>.gguf.
//
// The engine exposes:
//   - loadModel(path)         : hot-loads a .gguf into RAM/VRAM
//   - generate(prompt, opts)  : streaming token generator
//   - embed(text)             : returns a 384-dim vector for sqlite-vec
//   - unload()                : frees the model
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/flight_recorder.dart';
import '../../core/utils/logger.dart';

class LlmEngine {
  LlmEngine() : _log = Logger('LlmEngine');

  final Logger _log;
  LlamaParent? _model;

  /// v0.4.3 — the context window the current model was loaded with,
  /// so callers can budget prompts instead of overflowing nCtx.
  int loadedCtx = 4096;

  /// v0.4.4 — snapshot of the freshly-loaded (empty) KV state.
  /// The child isolate's position counter accumulates across EVERY
  /// prompt and reply and is never reset — once it nears nCtx,
  /// setPrompt throws "Context full" instantly (the 117 ms empty
  /// generations that got worse the longer a session ran). Restoring
  /// this clean snapshot before each generation resets the counter;
  /// we resend the full prompt every turn anyway, so no state is lost.
  Uint8List? _cleanState;
  bool _loading = false;

  StreamSubscription<String>? _sub;
  StreamSubscription? _compSub;
  StreamController<String>? _controller;

  bool get isLoaded => _model != null;
  bool get isLoading => _loading;

  /// Load a .gguf model from disk into process memory in a background isolate.
  /// Throws if the path doesn't exist or the file is corrupt.
  Future<void> loadModel(
    String ggufPath, {
    required int contextTokens,
    required int gpuLayers,
  }) async {
    if (_loading) {
      _log.warn('loadModel called while already loading; ignoring.');
      return;
    }
    if (!File(ggufPath).existsSync()) {
      throw FileSystemException('GGUF not found', ggufPath);
    }
    _loading = true;
    try {
      loadedCtx = contextTokens;
      _log.info('Loading model in background isolate: $ggufPath '
          '(ctx=$contextTokens, gpu_layers=$gpuLayers)');
      // llama_cpp_dart on Windows uses DynamicLibrary.process() by default,
      // which requires llama symbols to be linked into the exe — they aren't.
      // Load llama.dll explicitly, searching the places it can legitimately
      // live, and fail with an ACTIONABLE message instead of an FFI crash.
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = <String>[
          '$exeDir\\llama.dll',              // beside the built .exe
          'llama.dll',                        // current working dir
          'build\\windows\\x64\\runner\\Debug\\llama.dll',
          'build\\windows\\x64\\runner\\Release\\llama.dll',
        ];
        final found = candidates.firstWhere(
          (c) => File(c).existsSync(),
          orElse: () => '',
        );
        if (found.isEmpty) {
          throw StateError(
            'llama.dll not found. It is compiled automatically by the '
            'Windows build (llama_shared target in windows/runner). '
            'Fix: close any running tim_project.exe, then\n'
            '  flutter clean\n'
            '  flutter run -d windows\n'
            '(Searched: beside the exe, CWD, and '
            'build\\windows\\x64\\runner\\{Debug,Release}.)',
          );
        }
        Llama.libraryPath = found;
        _log.info('Using llama.dll at: $found');
      }

      final modelParams = ModelParams()
        ..nGpuLayers = gpuLayers
        ..mainGpu = -1;
      final contextParams = ContextParams()
        ..nCtx = contextTokens
        // Logical-core count oversubscribes llama.cpp on hybrid CPUs
        // (P+E cores, hyperthreading). Physical-core estimate is faster
        // and keeps the UI thread responsive during generation.
        ..nThreads = (Platform.numberOfProcessors ~/ 2) < 2
            ? 2
            : Platform.numberOfProcessors ~/ 2
        // v0.4.1 — nThreadsBatch governs PREFILL (prompt processing),
        // which is exactly the 'thirty seconds for hi' phase. It
        // defaulted to 8 regardless of hardware; on a 20-logical-core
        // machine prefill was leaving half the CPU idle.
        ..nThreadsBatch = (Platform.numberOfProcessors ~/ 2) < 2
            ? 2
            : Platform.numberOfProcessors ~/ 2;

      final loadCommand = LlamaLoad(
        path: ggufPath,
        modelParams: modelParams,
        contextParams: contextParams,
        samplingParams: SamplerParams(),
      );

      final parent = LlamaParent(loadCommand);
      _model = parent;
      await parent.init();
      _log.info('Model loaded successfully.');
      try {
        final snapScope = _model!.getScope();
        _cleanState = await _model!.saveState(snapScope);
        await _model!.disposeScope(snapScope);
        FlightRecorder.I
            .log('llm: clean-state snapshot ${_cleanState!.length} bytes');
      } catch (e) {
        _log.warn('Clean-state snapshot failed (context will accumulate '
            'until reload): $e');
        FlightRecorder.I.error('llm snapshot failed: $e');
      }
    } finally {
      _loading = false;
    }
  }

  bool _cancelled = false;

  /// Abort any in-flight generation. Safe to call from outside the isolate.
  void cancelGeneration() {
    _cancelled = true;
    _model?.stop();
    _sub?.cancel();
    _sub = null;
    _compSub?.cancel();
    _compSub = null;
    if (_controller != null && !_controller!.isClosed) {
      _controller!.close();
    }
    _controller = null;
  }

  /// Stream tokens for a chat-style completion using background isolate.
  Stream<String> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
    List<String> stop = const [],
  }) async* {
    if (_model == null) {
      throw StateError('LLM not loaded. Call loadModel() first.');
    }

    _cancelled = false;

    // Cancel any previous active streams/subscriptions to prevent duplicate token rendering.
    await _sub?.cancel();
    _sub = null;
    await _compSub?.cancel();
    _compSub = null;
    if (_controller != null && !_controller!.isClosed) {
      await _controller!.close();
    }
    _controller = null;

    // Stop any active generation first
    await _model!.stop();

    final scope = _model!.getScope();

    // v0.4.4 — fresh context every turn (see _cleanState).
    if (_cleanState != null) {
      try {
        await _model!.loadState(scope, _cleanState!);
      } catch (e) {
        FlightRecorder.I.error('llm state reset failed: $e');
      }
    }

    // Set up a local stream controller for this generation session
    final controller = StreamController<String>();
    _controller = controller;

    // Listen to the scope stream and forward tokens to the controller
    final sub = scope.stream.listen(
      (token) => controller.add(token),
      onError: (Object e, StackTrace s) => controller.addError(e, s),
    );
    _sub = sub;

    // Listen for completion events to close the controller
    final compSub = scope.completions.listen((event) {
      // v0.4.4 — the completion event carries the REAL failure reason
      // (e.g. "Context full"); it was being discarded, leaving only a
      // mysterious 0-char generation. Now it lands in the recorder.
      if (event.success) {
        FlightRecorder.I.log('llm: completion ok');
      } else {
        FlightRecorder.I.error(
            'llm completion FAILED: ${event.errorDetails ?? 'unknown'}');
      }
      if (!controller.isClosed) {
        controller.close();
      }
    });
    _compSub = compSub;

    try {
      // Send prompt to background isolate using the isolated scope
      await scope.sendPrompt(prompt);

      // ---- Stop-sequence HOLDBACK buffer ------------------------
      // The old loop checked stop markers only after tokens were
      // already yielded, so multi-token markers like <|eot_id|> leaked
      // into the chat UI as "<|eot_id|". We now hold back any tail of
      // the pending text that could still grow into a stop marker and
      // only emit text that provably cannot be part of one.
      final stopLower = stop.map((s) => s.toLowerCase()).toList();
      var produced = 0;
      var pending = '';

      int holdbackLen(String lcPending) {
        var hold = 0;
        for (final seq in stopLower) {
          final maxK = seq.length - 1;
          final limit = maxK < lcPending.length ? maxK : lcPending.length;
          for (var k = limit; k > 0; k--) {
            if (lcPending.endsWith(seq.substring(0, k))) {
              if (k > hold) hold = k;
              break;
            }
          }
        }
        return hold;
      }

      await for (final token in controller.stream) {
        if (_cancelled) break;
        produced++;
        pending += token;
        final lc = pending.toLowerCase();

        // Full stop marker present → emit only what precedes it, stop.
        var stopIdx = -1;
        String stopSeqFound = '';
        for (final seq in stopLower) {
          final idx = lc.indexOf(seq);
          if (idx != -1 && (stopIdx == -1 || idx < stopIdx)) {
            stopIdx = idx;
            stopSeqFound = seq;
          }
        }
        if (stopIdx != -1) {
          final safe = pending.substring(0, stopIdx);
          if (safe.isNotEmpty) yield safe;
          _log.info(
              'Stop sequence "$stopSeqFound" detected; stopping generation.');
          await scope.stop();
          pending = '';
          break;
        }

        // Otherwise emit everything except a tail that might still
        // become a stop marker.
        final hold = holdbackLen(lc);
        if (pending.length > hold) {
          yield pending.substring(0, pending.length - hold);
          pending = pending.substring(pending.length - hold);
        }

        if (produced >= maxTokens) {
          _log.warn('Hit maxTokens=$maxTokens; stopping generation.');
          await scope.stop();
          break;
        }
      }
      // Stream ended without a stop marker: flush the held-back tail.
      if (!_cancelled && pending.isNotEmpty) {
        yield pending;
      }
    } finally {
      await sub.cancel();
      await compSub.cancel();
      if (!controller.isClosed) {
        await controller.close();
      }
      try {
        await scope.dispose();
      } catch (e) {
        _log.warn('Failed to dispose model scope: $e');
      }
    }
  }

  /// Compute a 384-dim embedding for `text` (used by sqlite-vec).
  Future<List<double>> embed(String text) async {
    if (_model == null) {
      return hashEmbed(text);
    }
    try {
      final emb = await _model!.getEmbeddings(text);
      if (emb.isEmpty) return hashEmbed(text);
      return emb;
    } catch (_) {
      return hashEmbed(text);
    }
  }

  /// Unload the model and free native memory.
  void unload() {
    _model?.dispose();
    _model = null;
    _log.info('Model unloaded.');
  }

  // ---- fast hash embedder (public) --------------------------
  /// Deterministic hash-based embedder. NOT semantically meaningful —
  /// used as a fast, synchronous fallback so the RAG pipeline can run
  /// without blocking on the LLM isolate.
  static List<double> hashEmbed(String text) =>
      _hashEmbedImpl(text, TimConstants.embeddingDim);

  static List<double> _hashEmbedImpl(String text, int dim) {
    final out = List<double>.filled(dim, 0.0);
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      out[(c * 31 + i) % dim] += 1.0;
    }
    // L2-normalise.
    final norm = out.fold<double>(0.0, (a, b) => a + b * b);
    if (norm > 0) {
      final sqrtNorm = sqrt(norm);
      for (var i = 0; i < dim; i++) {
        out[i] /= sqrtNorm;
      }
    }
    return out;
  }

  static double sqrt(double x) {
    // Tiny stdlib shim — avoids dart:math import noise.
    return x <= 0 ? 0.0 : _newton(x, x / 2, 0);
  }

  static double _newton(double s, double x, int iter) {
    if (iter > 40) return x;
    final next = (x + s / x) / 2;
    return (next - x).abs() < 1e-9 ? next : _newton(s, next, iter + 1);
  }
}
