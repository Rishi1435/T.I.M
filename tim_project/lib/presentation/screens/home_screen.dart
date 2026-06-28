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
import '../widgets/sidebar.dart';
import '../widgets/voice_indicator.dart';
import '../widgets/model_selection_dialog.dart';
import 'genesis_screen.dart';
import 'live_call_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _sidebarExpanded = true;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat  = ref.watch(chatProvider);
    final hw    = ref.watch(hardwareProvider);
    final model = ref.watch(modelProvider);
    final voice = ref.watch(voiceCallProvider);
    final onboardingDone = ref.watch(onboardingCompletedProvider);

    // Auto-scroll when tokens arrive
    if (chat.isGenerating) _scrollToBottom();

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
                    // Thin generating progress shimmer
                    if (chat.isGenerating)
                      const LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                      ),
                    if (!onboardingDone)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E2F),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF3C3C5E)),
                          ),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.auto_awesome, color: Color(0xFFFFB74D), size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Help T.I.M. get to know you',
                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                "I don't know anything about you to start our journey. For a better experience, please give me some of your information.",
                                style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF3367D6),
                                  minimumSize: const Size(0, 36),
                                ),
                                icon: const Icon(Icons.rocket_launch, size: 16),
                                label: const Text('Go to Genesis Onboarding', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const GenesisScreen(),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Chat history
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        itemCount: chat.messages.length,
                        itemBuilder: (_, i) {
                          final msg = chat.messages[i];
                          final isStreaming = chat.isGenerating &&
                              msg.id == chat.streamingMessageId;
                          return MessageBubble(
                            message: msg,
                            isStreaming: isStreaming,
                          );
                        },
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
                          if (chat.isGenerating)
                            // ── Stop button ──────────────────────────────
                            _StopButton(
                              onStop: () => ref.read(chatProvider.notifier).stopGeneration(),
                            )
                          else
                            ChatInput(
                              onSend: (text) =>
                                  ref.read(chatProvider.notifier).sendText(text),
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
    final Widget chip;
    if (state.phase == ModelPhase.ready && state.selected != null) {
      chip = ActionChip(
        avatar: const Icon(Icons.memory, size: 16, color: Color(0xFF81C995)),
        label: Text('${state.selected!.label} (Change)'),
        onPressed: () => _showSelectionDialog(context),
      );
    } else if (state.phase == ModelPhase.downloading) {
      chip = ActionChip(
        avatar: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
          ),
        ),
        label: Text(
          'Downloading ${(state.downloadProgress * 100).toStringAsFixed(0)}%',
        ),
        onPressed: () => _showSelectionDialog(context),
      );
    } else if (state.phase == ModelPhase.paused) {
      chip = ActionChip(
        avatar: const Icon(Icons.pause, size: 16, color: Color(0xFFE57373)),
        label: Text(
          'Paused ${(state.downloadProgress * 100).toStringAsFixed(0)}%',
        ),
        onPressed: () => _showSelectionDialog(context),
      );
    } else if (state.phase == ModelPhase.loading) {
      chip = ActionChip(
        avatar: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFB74D)),
          ),
        ),
        label: const Text('Loading model…'),
        onPressed: () => _showSelectionDialog(context),
      );
    } else if (state.phase == ModelPhase.error) {
      chip = ActionChip(
        avatar: const Icon(Icons.error, size: 16, color: Colors.redAccent),
        label: const Text('Model error (Click to fix)'),
        onPressed: () => _showSelectionDialog(context),
      );
    } else {
      final rec = state.recommended;
      if (rec != null) {
        chip = ActionChip(
          avatar: const Icon(Icons.download, size: 16, color: Color(0xFF8AB4F8)),
          label: Text('Get ${rec.label} (${rec.sizeGb.toStringAsFixed(1)} GB)'),
          onPressed: () => _showSelectionDialog(context),
        );
      } else {
        chip = ActionChip(
          avatar: const Icon(Icons.download, size: 16),
          label: const Text('Get a model'),
          onPressed: () => _showSelectionDialog(context),
        );
      }
    }
    return chip;
  }

  void _showSelectionDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const ModelSelectionDialog(),
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

/// Animated stop button shown in the input dock while the LLM is generating.
class _StopButton extends StatefulWidget {
  const _StopButton({required this.onStop});
  final VoidCallback onStop;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Pulsing generation indicator
        FadeTransition(
          opacity: _pulse,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF8AB4F8),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'T.I.M. is thinking…',
                style: TextStyle(
                  color: Color(0xFF9AA0A6),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        // Stop button
        OutlinedButton.icon(
          onPressed: widget.onStop,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFE57373),
            side: const BorderSide(color: Color(0xFFE57373), width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          icon: const Icon(Icons.stop_rounded, size: 16),
          label: const Text('Stop', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}
