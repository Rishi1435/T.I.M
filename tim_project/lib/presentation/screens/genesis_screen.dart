// ============================================================
// lib/presentation/screens/genesis_screen.dart
// Phase 3 — Genesis Onboarding.
//
// Flow:
//   blank    -> "I don't know your story yet. Drop your resume, or
//               tell me about your journey."
//   drafting -> resume dropped; LLM extracting Memory Blocks
//   review   -> user edits / deletes / adds blocks (Memory Block cards)
//   confirmed-> vectorise + persist into the local vault
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    final modelReady = modelState.phase == ModelPhase.ready;

    return Scaffold(
      appBar: AppBar(title: const Text('Genesis — getting to know you')),
      body: Column(
        children: [
          // ---- Model download card (always visible when not ready) ----
          if (!modelReady)
            _ModelDownloadCard(
              modelState: modelState,
              onDownload: () {
                // Always read fresh — never capture notifier at build time
                // or it becomes stale after hardware re-init disposes it.
                ref.read(modelProvider.notifier).downloadAndLoad();
              },
              onPause: () {
                ref.read(modelProvider.notifier).pauseDownload();
              },
            ),
          // ---- Genesis error banner (e.g. tried to extract without model) ----
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
                      const SizedBox(height: 16),
                      Text(
                        state.extracting
                            ? 'Reading your story…'
                            : 'Drafting Memory Blocks…',
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
        color: const Color(0xFF1A1A2E),
        border: Border(
          bottom: BorderSide(
            color: isWorking
                ? const Color(0xFF8AB4F8)
                : hasError
                    ? const Color(0xFFCF6679)
                    : isPaused
                        ? const Color(0xFFE57373)
                        : const Color(0xFF3C3C5E),
            width: 1.5,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Row 1: icon + title + badge ----
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF252540),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.memory_rounded,
                  color: Color(0xFF8AB4F8),
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
                        color: Color(0xFFE8EAED),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (model != null)
                      Text(
                        '${model.sizeGb.toStringAsFixed(1)} GB  •  '
                        'Requires ${model.minRamGb.toStringAsFixed(0)} GB RAM',
                        style: const TextStyle(
                          color: Color(0xFF9AA0A6),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Phase badge
              _PhaseBadge(phase: phase),
            ],
          ),

          // ---- Row 2: progress bar (only when downloading, paused, or loading) ----
          if (isWorking || isPaused) ..._buildProgressSection(isDownloading, isPaused, isLoading, progress),

          // ---- Row 3: action button or error ----
          const SizedBox(height: 12),
          if (hasError)
            Text(
              modelState.error ?? 'An error occurred.',
              style: const TextStyle(
                color: Color(0xFFCF6679),
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
                  backgroundColor: const Color(0xFFCF6679),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
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
                  backgroundColor: const Color(0xFF3367D6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: onDownload,
              ),
            )
          else if (!isWorking) ...[
              // On-disk detection sub-label
              if (model != null) ...[
                Row(
                  children: [
                    Icon(
                      modelState.isOnDisk
                          ? Icons.check_circle_outline
                          : Icons.cloud_download_outlined,
                      size: 13,
                      color: modelState.isOnDisk
                          ? const Color(0xFF81C995)
                          : const Color(0xFF9AA0A6),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        modelState.isOnDisk
                            ? 'Model found on disk — ready to load'
                            : 'Not downloaded yet — ${model.sizeGb.toStringAsFixed(1)} GB required',
                        style: TextStyle(
                          color: modelState.isOnDisk
                              ? const Color(0xFF81C995)
                              : const Color(0xFF9AA0A6),
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
                        ? const Color(0xFF1E5631)
                        : const Color(0xFF3367D6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
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
  ) {
    final percent = (progress * 100).clamp(0.0, 100.0);
    final speed = modelState.downloadSpeedBps;
    final eta = modelState.downloadEtaSeconds;
    final received = modelState.downloadBytesReceived;
    final total = modelState.downloadTotalBytes;

    // Format helpers
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
            color: Color(0xFFFFB74D),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        )
      else ...[
        // Top row: label + percentage
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isPaused
                  ? 'Download paused'
                  : 'Downloading with 8 connections…',
              style: TextStyle(
                color: isPaused ? const Color(0xFFE57373) : const Color(0xFF8AB4F8),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              '${percent.toStringAsFixed(1)}%',
              style: TextStyle(
                color: isPaused ? const Color(0xFFE57373) : const Color(0xFF8AB4F8),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Bottom row: received/total · speed · ETA
        Row(
          children: [
            Text(
              total > 0
                  ? '${fmtBytes(received)} / ${fmtBytes(total)}'
                  : fmtBytes(received),
              style: const TextStyle(
                color: Color(0xFF9AA0A6),
                fontSize: 11,
              ),
            ),
            const Spacer(),
            if (!isPaused) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF252540),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  fmtSpeed(speed),
                  style: const TextStyle(
                    color: Color(0xFF8AB4F8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'ETA ${fmtEta(eta)}',
                style: const TextStyle(
                  color: Color(0xFF9AA0A6),
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
          backgroundColor: const Color(0xFF3C3C5E),
          valueColor:
              AlwaysStoppedAnimation<Color>(isPaused ? const Color(0xFFE57373) : const Color(0xFF8AB4F8)),
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
    final (label, color) = switch (phase) {
      ModelPhase.idle => ('Not Downloaded', const Color(0xFF9AA0A6)),
      ModelPhase.recommending => ('Selecting…', const Color(0xFFFFB74D)),
      ModelPhase.downloading => ('Downloading', const Color(0xFF8AB4F8)),
      ModelPhase.paused => ('Paused', const Color(0xFFE57373)),
      ModelPhase.loading => ('Loading', const Color(0xFFFFB74D)),
      ModelPhase.ready => ('Ready', const Color(0xFF81C995)),
      ModelPhase.error => ('Error', const Color(0xFFCF6679)),
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

// ---- Simple error banner ----
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3B1A1F),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: Color(0xFFCF6679),
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFFE8A0A8),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, size: 48,
                  color: Color(0xFF8AB4F8),),
              const SizedBox(height: 16),
              Text(
                'I don\'t know your story yet.',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Let\'s change that. Drop your resume, or tell me about '
                'your journey.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              // Drag-and-drop zone for PDFs / text files.
              DragDropZone(
                onText: (text) => onResume(text),
                onFile: (path) {
                  // Stub: real impl reads PDF via syncfusion_flutter_pdf.
                  onResume('Path dropped: $path');
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: journeyCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Or type a few paragraphs about yourself…',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                // Disable the button until model is ready
                onPressed:
                    modelReady ? () => onTellJourney(journeyCtrl.text) : null,
                child: Text(
                  modelReady
                      ? 'Tell T.I.M. my story'
                      : 'Waiting for model…',
                ),
              ),
            ],
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Confirm what I learned. Edit, delete, or add context '
                  'before I save it.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Confirm all & save'),
                onPressed: () => ctrl.confirmAll(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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

class _ConfirmedGate extends StatelessWidget {
  const _ConfirmedGate({required this.ctrl});
  final GenesisController ctrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_open, size: 48,
              color: Color(0xFF81C995),),
          const SizedBox(height: 16),
          Text('Memory baseline saved.',
              style: Theme.of(context).textTheme.titleLarge,),
          const SizedBox(height: 8),
          const Text(
            'Your vault is now encrypted and ready. T.I.M. will only '
            'remember what you confirmed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
