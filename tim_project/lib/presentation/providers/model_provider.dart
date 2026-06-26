// ============================================================
// lib/presentation/providers/model_provider.dart
// Phase 2 — picks + downloads + loads the optimal .gguf for the
// current hardware. Handles manual override + safety modal.
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../data/services/llm_engine.dart';
import '../../data/services/model_downloader.dart';
import '../../platform/channels/hardware_scanner.dart';
import 'hardware_provider.dart';

enum ModelPhase { idle, recommending, downloading, loading, ready, error }

@immutable
class ModelState {
  const ModelState({
    this.phase = ModelPhase.idle,
    this.recommended,
    this.selected,
    this.downloadProgress = 0.0,
    this.error,
  });

  final ModelPhase phase;
  final GgufModel? recommended;
  final GgufModel? selected;
  final double downloadProgress;
  final String? error;

  ModelState copyWith({
    ModelPhase? phase,
    GgufModel? recommended,
    GgufModel? selected,
    double? downloadProgress,
    String? error,
  }) =>
      ModelState(
        phase: phase ?? this.phase,
        recommended: recommended ?? this.recommended,
        selected: selected ?? this.selected,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        error: error ?? this.error,
      );
}

class ModelController extends StateNotifier<ModelState> {
  ModelController(this._hw, this._downloader, this._engine)
      : super(const ModelState());

  final HardwareProfile _hw;
  final ModelDownloader _downloader;
  final LlmEngine _engine;

  /// Run the hardware-aware recommendation algorithm.
  void recommend() {
    state = state.copyWith(phase: ModelPhase.recommending);
    final rec = _pick();
    state = state.copyWith(
      phase: ModelPhase.idle,
      recommended: rec,
      selected: rec,
    );
  }

  GgufModel _pick() {
    // Phase 2 rules:
    //   Plugged in + 16GB+ RAM + 6GB+ VRAM  → Llama 3 (8B)
    //   Plugged in + 24GB+ RAM + 8GB+ VRAM  → Qwen3 (14B)
    //   Battery or < 8GB RAM                → Qwen2.5 (3B) or Phi-3-Mini
    if (_hw.isHighSpec) {
      if (_hw.totalRamGb >= 24 && _hw.dedicatedVramGb >= 8) {
        return AppConfig.modelRegistry['qwen3-14b']!;
      }
      return AppConfig.modelRegistry['llama3-8b']!;
    }
    // Low-spec / battery: prefer Phi-3-Mini if very tight, else Qwen2.5.
    if (_hw.totalRamGb < 8) {
      return AppConfig.modelRegistry['phi3-mini']!;
    }
    return AppConfig.modelRegistry['qwen25-3b']!;
  }

  /// Override the recommendation (e.g. user forces 14B on battery).
  /// Returns `true` if a safety warning should be shown.
  bool selectManual(GgufModel model) {
    final warns = _isRisky(model);
    state = state.copyWith(selected: model);
    return warns;
  }

  bool _isRisky(GgufModel m) {
    if (!_hw.isCharging && !m.batteryOk) return true;
    if (_hw.totalRamGb < m.minRamGb) return true;
    if (m.minVramGb > 0 && _hw.dedicatedVramGb < m.minVramGb) return true;
    return false;
  }

  /// Download + load the currently selected model.
  Future<void> downloadAndLoad() async {
    final m = state.selected;
    if (m == null) {
      state = state.copyWith(
        phase: ModelPhase.error,
        error: 'No model selected',
      );
      return;
    }
    try {
      // Skip download if already on disk.
      if (!await _downloader.isDownloaded(m.id)) {
        state = state.copyWith(phase: ModelPhase.downloading);
        await for (final p in _downloader.download(m)) {
          state = state.copyWith(downloadProgress: p);
        }
      }
      state = state.copyWith(
        phase: ModelPhase.loading,
        downloadProgress: 1.0,
      );
      final path = await _downloader.ggufPath(m.id);
      // GPU layers: full offload if VRAM >= minVram, else 0.
      final gpuLayers = (_hw.dedicatedVramGb >= m.minVramGb) ? 99 : 0;
      await _engine.loadModel(path, contextTokens: 4096, gpuLayers: gpuLayers);
      state = state.copyWith(phase: ModelPhase.ready);
    } catch (e) {
      state = state.copyWith(phase: ModelPhase.error, error: '$e');
    }
  }
}

final modelDownloaderProvider =
    Provider<ModelDownloader>((ref) => ModelDownloader());
final llmEngineProvider = Provider<LlmEngine>((ref) => LlmEngine());

final modelProvider = StateNotifierProvider<ModelController, ModelState>(
  (ref) {
    final hwAsync = ref.watch(hardwareProvider);
    final hw = hwAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const HardwareProfile(
        totalRamGb: 16,
        availableRamGb: 8,
        dedicatedVramGb: 0,
        batteryPercent: 100,
        isCharging: true,
        gpuName: 'fallback',
      ),
    );
    return ModelController(
      hw,
      ref.read(modelDownloaderProvider),
      ref.read(llmEngineProvider),
    );
  },
);
