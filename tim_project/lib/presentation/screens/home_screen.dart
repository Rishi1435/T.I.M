// ============================================================
// lib/presentation/screens/home_screen.dart
// Phase 1 — Gemini-style layout: collapsible sidebar + dynamic main
// workspace with a universal drag-and-drop input zone. File chips
// render visually before sending.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/hardware_provider.dart';
import '../providers/model_provider.dart';
import '../providers/voice_provider.dart';
import '../widgets/chat_input.dart';
import '../widgets/file_chip_row.dart';
import '../widgets/message_bubble.dart';
import '../widgets/override_modal.dart';
import '../widgets/sidebar.dart';
import '../widgets/voice_indicator.dart';
import 'live_call_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _sidebarExpanded = true;

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final hw = ref.watch(hardwareProvider);
    final model = ref.watch(modelProvider);
    final voice = ref.watch(voiceCallProvider);

    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              // ----- Sidebar -----
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _sidebarExpanded ? 264 : 72,
                child: Sidebar(
                  expanded: _sidebarExpanded,
                  onToggle: () =>
                      setState(() => _sidebarExpanded = !_sidebarExpanded),
                ),
              ),
              // ----- Main workspace -----
              Expanded(
                child: Column(
                  children: [
                    // Top bar: hardware + model + connection status
                    Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 0.5,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Text(
                              'T.I.M.',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const Spacer(),
                            // Hardware badge
                            hw.when(
                              data: (p) => Tooltip(
                                message: p.toString(),
                                child: Chip(
                                  label: Text(
                                      '${p.totalRamGb.toStringAsFixed(0)}GB RAM • '
                                      '${p.dedicatedVramGb.toStringAsFixed(0)}GB VRAM • '
                                      '${p.batteryPercent}%'),
                                ),
                              ),
                              loading: () => const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              error: (_, __) => const SizedBox.shrink(),
                            ),
                            const SizedBox(width: 8),
                            // Model badge
                            _ModelBadge(state: model),
                            const SizedBox(width: 8),
                            Icon(
                              chat.connected
                                  ? Icons.cloud_done
                                  : Icons.cloud_off,
                              size: 18,
                              color: chat.connected
                                  ? Colors.green
                                  : Colors.redAccent,
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              tooltip: 'Sign out',
                              icon: const Icon(Icons.logout, size: 18),
                              onPressed: () =>
                                  ref.read(authProvider.notifier).signOut(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Chat history
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        itemCount: chat.messages.length,
                        itemBuilder: (_, i) =>
                            MessageBubble(message: chat.messages[i]),
                      ),
                    ),
                    // Pending file chips
                    if (chat.pendingChips.isNotEmpty)
                      FileChipRow(chips: chat.pendingChips),
                    // Voice / input dock
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        border: Border(
                          top: BorderSide(
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          if (chat.voice != VoiceState.idle)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: VoiceIndicator(state: chat.voice),
                            ),
                          ChatInput(
                            onSend: (text) => ref
                                .read(chatProvider.notifier)
                                .sendText(text),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // ----- Live Call overlay (Phase 5) -----
          if (voice.active)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: false,
                child: _LiveCallOverlay(),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModelBadge extends ConsumerWidget {
  const _ModelBadge({required this.state});
  final ModelState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.phase == ModelPhase.ready && state.selected != null) {
      return Chip(
        avatar: const Icon(Icons.memory, size: 16),
        label: Text(state.selected!.label),
      );
    }
    if (state.phase == ModelPhase.downloading) {
      return ActionChip(
        avatar: const Icon(Icons.pause, size: 16),
        label: Text(
          'Downloading ${(state.downloadProgress * 100).toStringAsFixed(0)}% (Pause)',
        ),
        onPressed: () {
          ref.read(modelProvider.notifier).pauseDownload();
        },
      );
    }
    if (state.phase == ModelPhase.paused) {
      return ActionChip(
        avatar: const Icon(Icons.play_arrow, size: 16),
        label: Text(
          'Paused ${(state.downloadProgress * 100).toStringAsFixed(0)}% (Resume)',
        ),
        onPressed: () {
          ref.read(modelProvider.notifier).downloadAndLoad();
        },
      );
    }
    if (state.phase == ModelPhase.loading) {
      return const Chip(label: Text('Loading model…'));
    }
    if (state.phase == ModelPhase.error) {
      return const Chip(
        avatar: Icon(Icons.error, size: 16, color: Colors.redAccent),
        label: Text('Model error'),
      );
    }
    // Idle / recommending — show the recommendation CTA.
    if (state.recommended == null) {
      return ActionChip(
        avatar: const Icon(Icons.download, size: 16),
        label: const Text('Get a model'),
        onPressed: () => ref.read(modelProvider.notifier).recommend(),
      );
    }
    return ActionChip(
      avatar: const Icon(Icons.download, size: 16),
      label: Text('Install ${state.recommended!.label}'),
      onPressed: () async {
        final risky = ref.read(modelProvider.notifier).selectManual(
              state.recommended!,
            );
        if (risky && context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) => OverrideModal(
              onConfirm: () => ref
                  .read(modelProvider.notifier)
                  .downloadAndLoad(),
            ),
          );
        } else {
          await ref.read(modelProvider.notifier).downloadAndLoad();
        }
      },
    );
  }
}

class _LiveCallOverlay extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pull the LiveCallView widget up from the widgets layer so this
    // file stays focused on layout composition.
    return Material(
      color: Colors.black.withValues(alpha: 0.85),
      child: const LiveCallView(),
    );
  }
}


