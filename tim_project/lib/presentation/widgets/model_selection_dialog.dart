// ============================================================
// lib/presentation/widgets/model_selection_dialog.dart
// Redesigned premium model management dialog.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../providers/model_provider.dart';
import '../providers/hardware_provider.dart';
import 'override_modal.dart';

class ModelSelectionDialog extends ConsumerStatefulWidget {
  const ModelSelectionDialog({super.key});

  @override
  ConsumerState<ModelSelectionDialog> createState() => _ModelSelectionDialogState();
}

class _ModelSelectionDialogState extends ConsumerState<ModelSelectionDialog> {
  final Map<String, bool> _downloadedCache = {};

  @override
  void initState() {
    super.initState();
    _checkAllDiskStatus();
  }

  Future<void> _checkAllDiskStatus() async {
    final downloader = ref.read(modelDownloaderProvider);
    for (final m in AppConfig.modelRegistry.values) {
      final exists = await downloader.isDownloaded(m.id);
      if (mounted) {
        setState(() {
          _downloadedCache[m.id] = exists;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final modelState = ref.watch(modelProvider);
    final hardwareAsync = ref.watch(hardwareProvider);
    final controller = ref.read(modelProvider.notifier);
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    return AlertDialog(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      title: Row(
        children: [
          Icon(Icons.settings_suggest_rounded, color: palette.primary, size: 28),
          const SizedBox(width: 12),
          const Text('Manage AI Models', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current hardware stats
            hardwareAsync.maybeWhen(
              data: (p) => Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: palette.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your system: ${p.totalRamGb.toStringAsFixed(0)}GB RAM | '
                        '${p.dedicatedVramGb.toStringAsFixed(0)}GB VRAM | '
                        '${p.isCharging ? "Charging" : "Battery"}',
                        style: TextStyle(fontSize: 11, color: palette.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 20),
            const Text(
              'Select a model to load or download:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: AppConfig.modelRegistry.values.map((model) {
                  final isRecommended = modelState.recommended?.id == model.id;
                  final isSelected = modelState.selected?.id == model.id;
                  final isDownloaded = _downloadedCache[model.id] ?? false;

                  final isActive = isSelected && modelState.phase == ModelPhase.ready;
                  final isCurrentlyDownloading = isSelected && modelState.phase == ModelPhase.downloading;
                  final isCurrentlyPaused = isSelected && modelState.phase == ModelPhase.paused;
                  final isCurrentlyLoading = isSelected && modelState.phase == ModelPhase.loading;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: palette.surfaceVariant,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive
                            ? palette.success
                            : isCurrentlyDownloading
                                ? palette.primary
                                : Colors.white.withValues(alpha: 0.05),
                        width: isActive ? 1.5 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                model.label,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Colors.white),
                              ),
                            ),
                            if (isRecommended)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: palette.success.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: palette.success.withValues(alpha: 0.2)),
                                ),
                                child: Text(
                                  'Suggested',
                                  style: TextStyle(color: palette.success, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Size: ${model.sizeGb.toStringAsFixed(1)} GB  •  '
                          'Min RAM: ${model.minRamGb.toStringAsFixed(0)} GB'
                          '${model.minVramGb > 0 ? "  •  Min VRAM: ${model.minVramGb.toStringAsFixed(0)} GB" : ""}',
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        if (isCurrentlyDownloading) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Downloading: ${(modelState.downloadProgress * 100).toStringAsFixed(0)}%',
                                style: TextStyle(color: palette.primary, fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: palette.danger,
                                ),
                                icon: const Icon(Icons.pause, size: 14),
                                label: const Text('Pause', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  controller.pauseDownload();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: modelState.downloadProgress,
                              minHeight: 4,
                              backgroundColor: Colors.black26,
                              valueColor: AlwaysStoppedAnimation<Color>(palette.primary),
                            ),
                          ),
                        ] else if (isCurrentlyPaused) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Paused: ${(modelState.downloadProgress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: palette.primary,
                                ),
                                icon: const Icon(Icons.play_arrow, size: 14),
                                label: const Text('Resume', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  await controller.downloadAndLoad();
                                  _checkAllDiskStatus();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: modelState.downloadProgress,
                              minHeight: 4,
                              backgroundColor: Colors.black26,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.orangeAccent),
                            ),
                          ),
                        ] else if (isCurrentlyLoading) ...[
                          const Row(
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.5, valueColor: AlwaysStoppedAnimation<Color>(Colors.orangeAccent)),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Loading model into memory...',
                                style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ] else ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (isActive)
                                Row(
                                  children: [
                                    Icon(Icons.check_circle_rounded, color: palette.success, size: 16),
                                    const SizedBox(width: 6),
                                    Text('Active', style: TextStyle(color: palette.success, fontSize: 13, fontWeight: FontWeight.w600)),
                                  ],
                                )
                              else
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size(0, 36),
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    backgroundColor: isDownloaded ? palette.success : palette.primary,
                                    foregroundColor: Colors.black,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: () async {
                                    final risky = controller.selectManual(model);
                                    if (risky) {
                                      final confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (_) => OverrideModal(
                                          onConfirm: () => Navigator.of(context).pop(true),
                                        ),
                                      );
                                      if (confirm != true) return;
                                    }
                                    await controller.downloadAndLoad();
                                    _checkAllDiskStatus();
                                  },
                                  child: Text(
                                    isDownloaded ? 'Load Model' : 'Download & Load',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close', style: TextStyle(color: palette.primary, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
