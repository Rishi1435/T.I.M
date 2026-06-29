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

enum ModelPhase { idle, recommending, downloading, paused, loading, ready, error }

@immutable
class ModelState {
  const ModelState({
    this.phase = ModelPhase.idle,
    this.recommended,
    this.selected,
    this.downloadProgress = 0.0,
    this.downloadSpeedBps = 0.0,
    this.downloadEtaSeconds = -1,
    this.downloadBytesReceived = 0,
    this.downloadTotalBytes = 0,
    this.isOnDisk = false,
    this.error,
  });

  final ModelPhase phase;
  final GgufModel? recommended;
  final GgufModel? selected;
  final double downloadProgress;
  final double downloadSpeedBps;
  final int downloadEtaSeconds;
  final int downloadBytesReceived;
  final int downloadTotalBytes;
  /// True if the selected model's .gguf already exists on disk.
  final bool isOnDisk;
  final String? error;

  ModelState copyWith({
    ModelPhase? phase,
    GgufModel? recommended,
    GgufModel? selected,
    double? downloadProgress,
    double? downloadSpeedBps,
    int? downloadEtaSeconds,
    int? downloadBytesReceived,
    int? downloadTotalBytes,
    bool? isOnDisk,
    String? error,
  }) =>
      ModelState(
        phase: phase ?? this.phase,
        recommended: recommended ?? this.recommended,
        selected: selected ?? this.selected,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        downloadSpeedBps: downloadSpeedBps ?? this.downloadSpeedBps,
        downloadEtaSeconds: downloadEtaSeconds ?? this.downloadEtaSeconds,
        downloadBytesReceived:
            downloadBytesReceived ?? this.downloadBytesReceived,
        downloadTotalBytes: downloadTotalBytes ?? this.downloadTotalBytes,
        isOnDisk: isOnDisk ?? this.isOnDisk,
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
    // After picking, check if it's already on disk.
    _checkDisk(rec);
  }

  /// Called once on creation — picks best model, checks disk.
  Future<void> initCheck() async {
    recommend();
  }

  Future<void> _checkDisk(GgufModel model) async {
    final onDisk = await _downloader.isDownloaded(model.id);
    if (mounted) {
      state = state.copyWith(isOnDisk: onDisk);
      if (onDisk) {
        downloadAndLoad();
      }
    }
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
        state = state.copyWith(
          phase: ModelPhase.downloading,
          downloadProgress: state.phase == ModelPhase.paused ? state.downloadProgress : 0.0,
          downloadSpeedBps: 0,
          downloadEtaSeconds: -1,
        );
        await for (final prog in _downloader.download(m)) {
          if (!mounted) return;
          state = state.copyWith(
            downloadProgress: prog.fraction,
            downloadSpeedBps: prog.speedBytesPerSec,
            downloadEtaSeconds: prog.etaSeconds,
            downloadBytesReceived: prog.bytesReceived,
            downloadTotalBytes: prog.totalBytes,
          );
        }
      }
      if (!mounted) return;
      state = state.copyWith(
        phase: ModelPhase.loading,
        downloadProgress: 1.0,
      );
      final path = await _downloader.ggufPath(m.id);
      // GPU layers: full offload if VRAM >= minVram (only when minVram > 0), else 0.
      final gpuLayers = (m.minVramGb > 0 && _hw.dedicatedVramGb >= m.minVramGb) ? 99 : 0;
      await _engine.loadModel(path, contextTokens: 4096, gpuLayers: gpuLayers);
      if (!mounted) return;
      state = state.copyWith(phase: ModelPhase.ready);
    } on DownloadPausedException {
      if (mounted) {
        state = state.copyWith(
          phase: ModelPhase.paused,
          downloadSpeedBps: 0,
          downloadEtaSeconds: -1,
        );
      }
    } catch (e) {
      if (mounted) state = state.copyWith(phase: ModelPhase.error, error: '$e');
    }
  }

  void pauseDownload() {
    if (state.phase == ModelPhase.downloading) {
      _downloader.cancelAll();
    }
  }
}

final modelDownloaderProvider =
    Provider<ModelDownloader>((ref) => ModelDownloader());
final llmEngineProvider = Provider<LlmEngine>((ref) => LlmEngine());

final modelProvider = StateNotifierProvider<ModelController, ModelState>(
  (ref) {
    // Use .read (not .watch) so the controller is NEVER disposed and recreated
    // when hardware data updates. A mid-session teardown causes the
    // "Tried to use ModelController after dispose" crash.
    final hwAsync = ref.read(hardwareProvider);
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
    final ctrl = ModelController(
      hw,
      ref.read(modelDownloaderProvider),
      ref.read(llmEngineProvider),
    );
    // Auto-pick best model and check disk on startup.
    ctrl.initCheck();
    return ctrl;
  },
);
