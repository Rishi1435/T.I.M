import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
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

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.settings_suggest_rounded, color: Color(0xFF8AB4F8), size: 28),
          SizedBox(width: 12),
          Text('Manage AI Models'),
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
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Color(0xFF9AA0A6)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your system: ${p.totalRamGb.toStringAsFixed(0)}GB RAM | '
                        '${p.dedicatedVramGb.toStringAsFixed(0)}GB VRAM | '
                        '${p.isCharging ? "Charging" : "Battery"}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
                      ),
                    ),
                  ],
                ),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),
            const Text(
              'Select a model to load or download:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: AppConfig.modelRegistry.values.map((model) {
                  final isRecommended = modelState.recommended?.id == model.id;
                  final isSelected = modelState.selected?.id == model.id;
                  final isDownloaded = _downloadedCache[model.id] ?? false;

                  // Check if this model is active/loaded
                  final isActive = isSelected && modelState.phase == ModelPhase.ready;
                  final isCurrentlyDownloading = isSelected && modelState.phase == ModelPhase.downloading;
                  final isCurrentlyPaused = isSelected && modelState.phase == ModelPhase.paused;
                  final isCurrentlyLoading = isSelected && modelState.phase == ModelPhase.loading;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2F),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isActive
                            ? const Color(0xFF81C995)
                            : isCurrentlyDownloading
                                ? const Color(0xFF8AB4F8)
                                : const Color(0xFF3C3C5E),
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
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ),
                            if (isRecommended)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF81C995).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: const Color(0xFF81C995).withValues(alpha: 0.4)),
                                ),
                                child: const Text(
                                  'Suggested',
                                  style: TextStyle(color: Color(0xFF81C995), fontSize: 9, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Size: ${model.sizeGb.toStringAsFixed(1)} GB  •  '
                          'Min RAM: ${model.minRamGb.toStringAsFixed(0)} GB'
                          '${model.minVramGb > 0 ? "  •  Min VRAM: ${model.minVramGb.toStringAsFixed(0)} GB" : ""}',
                          style: const TextStyle(color: Color(0xFF9AA0A6), fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        // Handle actions / progress for this model
                        if (isCurrentlyDownloading) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Downloading: ${(modelState.downloadProgress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(color: Color(0xFF8AB4F8), fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: const Color(0xFFCF6679),
                                ),
                                icon: const Icon(Icons.pause, size: 14),
                                label: const Text('Pause', style: TextStyle(fontSize: 11)),
                                onPressed: () {
                                  controller.pauseDownload();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: modelState.downloadProgress,
                              minHeight: 4,
                              backgroundColor: const Color(0xFF3C3C5E),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                            ),
                          ),
                        ] else if (isCurrentlyPaused) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Paused: ${(modelState.downloadProgress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(color: Color(0xFFE57373), fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: const Color(0xFF8AB4F8),
                                ),
                                icon: const Icon(Icons.play_arrow, size: 14),
                                label: const Text('Resume', style: TextStyle(fontSize: 11)),
                                onPressed: () async {
                                  await controller.downloadAndLoad();
                                  _checkAllDiskStatus();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: modelState.downloadProgress,
                              minHeight: 4,
                              backgroundColor: const Color(0xFF3C3C5E),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE57373)),
                            ),
                          ),
                        ] else if (isCurrentlyLoading) ...[
                          const Row(
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.5, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFB74D))),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Loading model into memory...',
                                style: TextStyle(color: Color(0xFFFFB74D), fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ] else ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (isActive)
                                const Row(
                                  children: [
                                    Icon(Icons.check_circle_rounded, color: Color(0xFF81C995), size: 16),
                                    SizedBox(width: 6),
                                    Text('Active', style: TextStyle(color: Color(0xFF81C995), fontSize: 12, fontWeight: FontWeight.w600)),
                                  ],
                                )
                              else
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size(0, 32),
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    backgroundColor: isDownloaded ? const Color(0xFF1E5631) : const Color(0xFF3367D6),
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
                                    style: const TextStyle(fontSize: 12),
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
          child: const Text('Close'),
        ),
      ],
    );
  }
}
