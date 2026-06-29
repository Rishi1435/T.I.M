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

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/logger.dart';

class LlmEngine {
  LlmEngine() : _log = Logger('LlmEngine');

  final Logger _log;
  LlamaParent? _model;
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
      _log.info('Loading model in background isolate: $ggufPath '
          '(ctx=$contextTokens, gpu_layers=$gpuLayers)');
      // llama_cpp_dart on Windows uses DynamicLibrary.process() by default,
      // which requires llama symbols to be linked into the exe — they aren't.
      // Instead, tell it to use DynamicLibrary.open('llama.dll') so it loads
      // from the DLL placed beside the exe by the build hook.
      if (Platform.isWindows) {
        Llama.libraryPath = 'llama.dll';
      }

      final modelParams = ModelParams()
        ..nGpuLayers = gpuLayers
        ..mainGpu = -1;
      final contextParams = ContextParams()
        ..nCtx = contextTokens
        ..nThreads = Platform.numberOfProcessors;

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
      if (!controller.isClosed) {
        controller.close();
      }
    });
    _compSub = compSub;

    try {
      // Send prompt to background isolate using the isolated scope
      await scope.sendPrompt(prompt);

      var produced = 0;
      var accumulated = '';
      await for (final token in controller.stream) {
        if (_cancelled) break;
        produced++;
        accumulated += token;

        bool shouldStop = false;
        String stopSeqFound = '';
        for (final seq in stop) {
          if (accumulated.toLowerCase().contains(seq.toLowerCase())) {
            shouldStop = true;
            stopSeqFound = seq;
            break;
          }
        }

        if (shouldStop) {
          _log.info(
              'Stop sequence "$stopSeqFound" detected; stopping generation.');
          await scope.stop();
          break;
        }

        yield token;

        if (produced >= maxTokens) {
          _log.warn('Hit maxTokens=$maxTokens; stopping generation.');
          await scope.stop();
          break;
        }
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
