// ============================================================
// lib/presentation/screens/genesis_screen.dart
// Redesigned premium Genesis onboarding screen.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/model_provider.dart';
import '../providers/onboarding_provider.dart';
import '../widgets/drag_drop_zone.dart';
import '../widgets/memory_block.dart';

class GenesisScreen extends ConsumerWidget {
  const GenesisScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(genesisProvider);
    final ctrl = ref.read(genesisProvider.notifier);
    final modelState = ref.watch(modelProvider);
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    final modelReady = modelState.phase == ModelPhase.ready;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Genesis — Getting to Know You'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.0, -0.4),
            radius: 1.2,
            colors: [
              palette.bgGlow,
              palette.bg,
            ],
            stops: const [0.0, 0.8],
          ),
        ),
        child: Column(
          children: [
            // ---- Model download card (always visible when not ready) ----
            if (!modelReady)
              _ModelDownloadCard(
                modelState: modelState,
                onDownload: () {
                  ref.read(modelProvider.notifier).downloadAndLoad();
                },
                onPause: () {
                  ref.read(modelProvider.notifier).pauseDownload();
                },
              ),
            // ---- Genesis error banner ----
            if (state.error != null)
              _ErrorBanner(message: state.error!),
            // ---- Main phase content ----
            Expanded(
              child: switch (state.phase) {
                GenesisPhase.blank => _BlankSlate(
                    modelReady: modelReady,
                    onResume: (text) => ctrl.extractFromResume(text),
                    onTellJourney: (text) => ctrl.extractFromResume(text),
                  ),
                GenesisPhase.drafting => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(
                          state.extracting
                              ? 'Reading your story…'
                              : 'Drafting Memory Blocks…',
                          style: TextStyle(color: palette.textSecondary, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                GenesisPhase.review =>
                  _ReviewDashboard(state: state, ctrl: ctrl),
                GenesisPhase.confirmed => _ConfirmedGate(ctrl: ctrl),
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// Model Download Card
// ----------------------------------------------------------------
class _ModelDownloadCard extends StatelessWidget {
  const _ModelDownloadCard({
    required this.modelState,
    required this.onDownload,
    required this.onPause,
  });
  final ModelState modelState;
  final VoidCallback onDownload;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final phase = modelState.phase;
    final model = modelState.selected ?? modelState.recommended;
    final progress = modelState.downloadProgress;
    final isDownloading = phase == ModelPhase.downloading;
    final isPaused = phase == ModelPhase.paused;
    final isLoading = phase == ModelPhase.loading;
    final isWorking = isDownloading || isLoading;
    final hasError = phase == ModelPhase.error;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(
            color: isWorking
                ? palette.primary
                : hasError
                    ? palette.danger
                    : isPaused
                        ? Colors.orangeAccent
                        : palette.surfaceVariant,
            width: 1.5,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: palette.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.memory_rounded,
                  color: palette.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model != null ? model.label : 'AI Model Required',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (model != null)
                      Text(
                        '${model.sizeGb.toStringAsFixed(1)} GB  •  '
                        'Requires ${model.minRamGb.toStringAsFixed(0)} GB RAM',
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _PhaseBadge(phase: phase),
            ],
          ),
          if (isWorking || isPaused) ..._buildProgressSection(isDownloading, isPaused, isLoading, progress, palette),
          const SizedBox(height: 12),
          if (hasError)
            Text(
              modelState.error ?? 'An error occurred.',
              style: TextStyle(
                color: palette.danger,
                fontSize: 12,
              ),
            )
          else if (isDownloading)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.pause_rounded, size: 18),
                label: const Text('Pause Download'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.danger,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onPause,
              ),
            )
          else if (isPaused)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(
                  model != null
                      ? 'Resume Download  (${(progress * 100).toStringAsFixed(1)}%)'
                      : 'Resume Download',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onDownload,
              ),
            )
          else if (!isWorking) ...[
              if (model != null) ...[
                Row(
                  children: [
                    Icon(
                      modelState.isOnDisk
                          ? Icons.check_circle_outline
                          : Icons.cloud_download_outlined,
                      size: 13,
                      color: modelState.isOnDisk
                          ? palette.success
                          : palette.muted,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        modelState.isOnDisk
                            ? 'Model found on disk — ready to load'
                            : 'Not downloaded yet — ${model.sizeGb.toStringAsFixed(1)} GB required',
                        style: TextStyle(
                          color: modelState.isOnDisk
                              ? palette.success
                              : palette.muted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: Icon(
                    modelState.isOnDisk
                        ? Icons.play_circle_outline_rounded
                        : Icons.download_rounded,
                    size: 18,
                  ),
                  label: Text(
                    modelState.isOnDisk
                        ? 'Load ${model?.label ?? 'Model'} into Memory'
                        : model != null
                            ? 'Download ${model.label}  (${model.sizeGb.toStringAsFixed(1)} GB)'
                            : 'Select & Download Model',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: modelState.isOnDisk
                        ? palette.success
                        : palette.primary,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: onDownload,
                ),
              ),
            ],
        ],
      ),
    );
  }

  List<Widget> _buildProgressSection(
    bool isDownloading,
    bool isPaused,
    bool isLoading,
    double progress,
    TimPalette palette,
  ) {
    final percent = (progress * 100).clamp(0.0, 100.0);
    final speed = modelState.downloadSpeedBps;
    final eta = modelState.downloadEtaSeconds;
    final received = modelState.downloadBytesReceived;
    final total = modelState.downloadTotalBytes;

    String fmtBytes(int b) {
      if (b <= 0) return '0 MB';
      final mb = b / (1024 * 1024);
      if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
      return '${mb.toStringAsFixed(0)} MB';
    }

    String fmtSpeed(double bps) {
      if (bps <= 0) return '…';
      final mb = bps / (1024 * 1024);
      if (mb >= 1) return '${mb.toStringAsFixed(1)} MB/s';
      return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    }

    String fmtEta(int s) {
      if (s < 0) return '—';
      if (s < 60) return '${s}s';
      if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
      return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
    }

    return [
      const SizedBox(height: 12),
      if (isLoading)
        const Text(
          'Loading model into memory…',
          style: TextStyle(
            color: Colors.orangeAccent,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        )
      else ...[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isPaused
                  ? 'Download paused'
                  : 'Downloading with 8 connections…',
              style: TextStyle(
                color: isPaused ? Colors.orangeAccent : palette.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              '${percent.toStringAsFixed(1)}%',
              style: TextStyle(
                color: isPaused ? Colors.orangeAccent : palette.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              total > 0
                  ? '${fmtBytes(received)} / ${fmtBytes(total)}'
                  : fmtBytes(received),
              style: TextStyle(
                color: palette.muted,
                fontSize: 11,
              ),
            ),
            const Spacer(),
            if (!isPaused) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  fmtSpeed(speed),
                  style: TextStyle(
                    color: palette.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'ETA ${fmtEta(eta)}',
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ],
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: isLoading ? null : progress,
          minHeight: 6,
          backgroundColor: palette.surfaceVariant,
          valueColor: AlwaysStoppedAnimation<Color>(
            isPaused
                ? Colors.orangeAccent
                : (isLoading ? Colors.orangeAccent : palette.primary),
          ),
        ),
      ),
    ];
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.phase});
  final ModelPhase phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final (label, color) = switch (phase) {
      ModelPhase.idle => ('Not Downloaded', palette.muted),
      ModelPhase.recommending => ('Selecting…', Colors.orangeAccent),
      ModelPhase.downloading => ('Downloading', palette.primary),
      ModelPhase.paused => ('Paused', Colors.orangeAccent),
      ModelPhase.loading => ('Loading', Colors.orangeAccent),
      ModelPhase.ready => ('Ready', palette.success),
      ModelPhase.error => ('Error', palette.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.danger.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: palette.danger.withValues(alpha: 0.2))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: palette.danger,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.danger,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlankSlate extends StatelessWidget {
  const _BlankSlate({
    required this.modelReady,
    required this.onResume,
    required this.onTellJourney,
  });
  final bool modelReady;
  final ValueChanged<String> onResume;
  final ValueChanged<String> onTellJourney;

  @override
  Widget build(BuildContext context) {
    final journeyCtrl = TextEditingController();
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 48,
                  color: palette.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'I don\'t know your story yet.',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Let\'s change that. Drop your resume, or tell me about your journey.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 24),
                DragDropZone(
                  onText: (text) => onResume(text),
                  onFile: (path) {
                    onResume('Path dropped: $path');
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: journeyCtrl,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: 'Or type a few paragraphs about yourself…',
                    hintStyle: TextStyle(color: palette.muted),
                    fillColor: palette.surface,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: modelReady ? () => onTellJourney(journeyCtrl.text) : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.primary,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      modelReady ? 'Tell T.I.M. my story' : 'Waiting for model…',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewDashboard extends StatelessWidget {
  const _ReviewDashboard({required this.state, required this.ctrl});
  final GenesisState state;
  final GenesisController ctrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Confirm what I learned. Edit, delete, or add context before I save it.',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: palette.primary,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Confirm & Save'),
                onPressed: () => ctrl.confirmAll(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: state.blocks.length,
            itemBuilder: (_, i) {
              final b = state.blocks[i];
              return MemoryBlockCard(
                block: b,
                onToggleConfirm: () => ctrl.toggleConfirm(b.draftId),
                onDelete: () => ctrl.deleteBlock(b.draftId),
                onEdit: (text) => ctrl.editBlock(b.draftId, text),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConfirmedGate extends ConsumerWidget {
  const _ConfirmedGate({required this.ctrl});
  final GenesisController ctrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_open,
                size: 56,
                color: palette.success,
              ),
              const SizedBox(height: 24),
              Text(
                'Memory baseline saved.',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your vault is now encrypted and ready. T.I.M. will only remember what you confirmed.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    ref.read(onboardingCompletedProvider.notifier).setCompleted(true);
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.primary,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Enter Chat Workspace', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
