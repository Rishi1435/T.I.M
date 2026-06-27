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
  Llama? _model;
  bool _loading = false;

  bool get isLoaded => _model != null;
  bool get isLoading => _loading;

  /// Load a .gguf model from disk into process memory.
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
      _log.info('Loading model: $ggufPath '
                '(ctx=$contextTokens, gpu_layers=$gpuLayers)');
      // llama_cpp_dart on Windows uses DynamicLibrary.process() by default,
      // which requires llama symbols to be linked into the exe — they aren't.
      // Instead, tell it to use DynamicLibrary.open('llama.dll') so it loads
      // from the DLL placed beside the exe by the build hook.
      if (Platform.isWindows) {
        Llama.libraryPath = 'llama.dll';
      }
      // Wrap in Future to avoid blocking the UI thread during disk I/O.
      _model = await Future(() {
        final modelParams = ModelParams()..nGpuLayers = gpuLayers;
        final contextParams = ContextParams()
          ..nCtx = contextTokens
          ..nThreads = Platform.numberOfProcessors;
        return Llama(
          ggufPath,
          modelParams: modelParams,
          contextParams: contextParams,
        );
      });
      _log.info('Model loaded.');
    } finally {
      _loading = false;
    }
  }

  /// Stream tokens for a chat-style completion.
  Stream<String> generate(
    String prompt, {
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    if (_model == null) {
      throw StateError('LLM not loaded. Call loadModel() first.');
    }
    final controller = StreamController<String>();
    try {
      _model!.setPrompt(prompt);
    } catch (e, s) {
      controller.addError(e, s);
    }
    final sub = _model!.generateText().listen(
      (token) => controller.add(token),
      onError: (Object e, StackTrace s) => controller.addError(e, s),
      onDone: () => controller.close(),
      cancelOnError: true,
    );
    // Safety cap: cancel after maxTokens to prevent runaway.
    var produced = 0;
    await for (final tok in controller.stream) {
      produced++;
      yield tok;
      if (produced >= maxTokens) {
        _log.warn('Hit maxTokens=$maxTokens; stopping generation.');
        break;
      }
    }
    await sub.cancel();
  }

  /// Compute a 384-dim embedding for `text` (used by sqlite-vec).
  /// Implementation note: when the loaded model is a pure causal LM
  /// without an embedding head, llama_cpp_dart returns an empty list.
  /// The Antigravity IDE agent should either ship a separate bge-small
  /// GGUF for embeddings, or fall back to a hashing embedder.
  Future<List<double>> embed(String text) async {
    if (_model == null) {
      // Fallback: trivial hash-based embedder (deterministic, dim=384).
      return _hashEmbed(text, TimConstants.embeddingDim);
    }
    final emb = _model!.getEmbeddings(text);
    if (emb.isEmpty) {
      return _hashEmbed(text, TimConstants.embeddingDim);
    }
    return emb;
  }

  /// Unload the model and free native memory.
  void unload() {
    _model?.dispose();
    _model = null;
    _log.info('Model unloaded.');
  }

  // ---- fallback embedder -----------------------------------------
  /// Deterministic hash-based embedder. NOT semantically meaningful —
  /// only used as a placeholder so the RAG pipeline can be exercised
  /// end-to-end before a real embedding model is provisioned.
  static List<double> _hashEmbed(String text, int dim) {
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
