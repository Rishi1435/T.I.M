// ============================================================
// lib/presentation/screens/home_screen.dart
// Overhauled home screen: collapsible sidebar navigation,
// radial gradient background, view-pane switcher, mode switcher,
// and premium chat input pill.
// ============================================================

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/file_chip.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/hardware_provider.dart';
import '../providers/model_provider.dart';
import '../providers/voice_provider.dart';
import '../widgets/file_chip_row.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sidebar.dart';
import '../widgets/model_selection_dialog.dart';
import 'genesis_screen.dart';
import 'live_call_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _sidebarExpanded = true;
  String _activeView = 'home'; // 'home', 'profile', 'settings'
  String _activeMode = 'chat'; // 'chat', 'live', 'screen'
  final _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
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

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    ref.read(chatProvider.notifier).sendText(text);
    _inputCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final hw = ref.watch(hardwareProvider);
    final model = ref.watch(modelProvider);
    final voice = ref.watch(voiceCallProvider);
    final onboardingDone = ref.watch(onboardingCompletedProvider);
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    // Auto-scroll when tokens arrive
    if (chat.isGenerating) _scrollToBottom();

    // Auto-scroll when messages list changes length
    ref.listen<int>(chatProvider.select((s) => s.messages.length), (prev, next) {
      _scrollToBottom();
    });

    // Determine main view-pane
    Widget mainPane;
    if (_activeView == 'profile') {
      mainPane = const ProfileScreen();
    } else if (_activeView == 'settings') {
      mainPane = const SettingsScreen();
    } else {
      // Home / Chat session view
      mainPane = _buildHomePane(context, chat, onboardingDone, palette, model);
    }

    return Scaffold(
      body: DropTarget(
        onDragDone: (details) {
          for (final f in details.files) {
            final chip = FileChip(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              name: f.name,
              kind: FileChip.inferKind(f.name),
              sizeBytes: 0,
              localUri: f.path,
            );
            ref.read(chatProvider.notifier).addFileChip(chip);
          }
        },
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        child: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.0, -0.4),
              radius: 1.2,
              colors: [
                _dragging ? palette.surfaceHover : palette.bgGlow,
                palette.bg,
              ],
              stops: const [0.0, 0.8],
            ),
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  // Collapsible Sidebar
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: _sidebarExpanded ? 280 : 72,
                    child: Sidebar(
                      expanded: _sidebarExpanded,
                      onToggle: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
                      activeView: _activeView,
                      onViewChanged: (view) => setState(() {
                        _activeView = view;
                        // Reset modes when shifting views
                        if (view == 'home') _activeMode = 'chat';
                      }),
                      onNewSession: () {
                        // Clear active session
                        ref.read(chatProvider.notifier).clearHistory();
                      },
                      onWorkspaceSelected: (workspace) {
                        setState(() {
                          _activeView = 'home';
                          _activeMode = 'chat';
                        });
                        // Simulate loading historic conversation workspace
                        ref.read(chatProvider.notifier).clearHistory();
                        ref.read(chatProvider.notifier).addSystem('Loaded Workspace: $workspace');
                      },
                    ),
                  ),

                  // Main View-Pane
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: mainPane),

                        // Floating Top Bar actions (Hardware, Model selectors, Status, Sign out)
                        Positioned(
                          top: 16,
                          right: 24,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Hardware stats
                              hw.when(
                                data: (p) => Tooltip(
                                  message: p.toString(),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.05),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                    ),
                                    child: Text(
                                      '${p.totalRamGb.toStringAsFixed(0)}GB RAM • '
                                      '${p.dedicatedVramGb.toStringAsFixed(0)}GB VRAM • '
                                      '${p.batteryStatusString}',
                                      style: TextStyle(color: palette.textSecondary, fontSize: 11),
                                    ),
                                  ),
                                ),
                                loading: () => const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 1.5),
                                ),
                                error: (_, __) => const SizedBox.shrink(),
                              ),
                              const SizedBox(width: 8),

                              // Model selection
                              _ModelBadge(state: model),
                              const SizedBox(width: 8),

                              // Connection status
                              Icon(
                                chat.connected ? Icons.cloud_done : Icons.cloud_off,
                                size: 16,
                                color: chat.connected ? palette.success : palette.danger,
                              ),
                              const SizedBox(width: 8),

                              // Sign out
                              IconButton(
                                tooltip: 'Sign out',
                                icon: Icon(Icons.logout, size: 16, color: palette.textSecondary),
                                onPressed: () => ref.read(authProvider.notifier).signOut(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Full-screen Live Call Waveform overlay (obscures screen on active speech)
              if (voice.active)
                Positioned.fill(
                  child: Container(
                    color: Colors.black,
                    child: const LiveCallView(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomePane(
    BuildContext context,
    ChatState chat,
    bool onboardingDone,
    TimPalette palette,
    ModelState model,
  ) {
    final showGreeting = chat.messages.isEmpty && _activeMode == 'chat';

    return Column(
      children: [
        const SizedBox(height: 24),
        // Floating Mode Switcher
        _buildModeSwitcher(palette),

        if ((model.phase == ModelPhase.loading || model.phase == ModelPhase.downloading) && _activeMode == 'chat')
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      model.phase == ModelPhase.loading
                          ? 'Loading T.I.M. model into memory…'
                          : 'Downloading model (${(model.downloadProgress * 100).toStringAsFixed(0)}%)…',
                      style: TextStyle(color: palette.textSecondary, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (chat.isGenerating && _activeMode == 'chat')
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFA8C7FA)),
            ),
          ),

        if (!onboardingDone && _activeMode == 'chat')
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
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
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "I don't know anything about you to start our journey. For a better experience, please give me some of your information.",
                    style: TextStyle(color: palette.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.primary,
                      foregroundColor: Colors.black,
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

        // Middle Viewport
        Expanded(
          child: _activeMode == 'live'
              ? _buildVoicePane(palette)
              : _activeMode == 'screen'
                  ? _buildScreenPane(palette)
                  : showGreeting
                      ? Center(
                          child: Text(
                            'Hi Rishi, let\'s get into it',
                            style: TextStyle(
                              color: palette.accent,
                              fontSize: 32,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.4,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          itemCount: chat.messages.length,
                          itemBuilder: (_, i) {
                            final msg = chat.messages[i];
                            final isStreaming = chat.isGenerating && msg.id == chat.streamingMessageId;
                            return MessageBubble(
                              message: msg,
                              isStreaming: isStreaming,
                            );
                          },
                        ),
        ),

        // File chips rendering
        if (chat.pendingChips.isNotEmpty && _activeMode == 'chat')
          FileChipRow(chips: chat.pendingChips),

        // Input pill (always visible in Chat mode, or adapted stops)
        if (_activeMode == 'chat')
          Padding(
            padding: const EdgeInsets.all(24),
            child: _buildInputPill(chat, palette, model),
          ),
      ],
    );
  }

  Widget _buildModeSwitcher(TimPalette palette) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeButton('chat', Icons.chat_bubble_outline, 'Chat', palette),
          _buildModeButton('live', Icons.graphic_eq, 'Live Call', palette),
          _buildModeButton('screen', Icons.screen_share_outlined, 'Screen Share', palette),
        ],
      ),
    );
  }

  Widget _buildModeButton(String mode, IconData icon, String label, TimPalette palette) {
    final isActive = _activeMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _activeMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? palette.surfaceVariant : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive ? Colors.white : palette.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isActive ? Colors.white : palette.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoicePane(TimPalette palette) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Ready for a mock interview?',
            style: TextStyle(
              color: palette.accent,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Press the mic button below to start the live call session.',
            style: TextStyle(color: palette.muted, fontSize: 14),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: Colors.black,
              minimumSize: const Size(200, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            ),
            icon: const Icon(Icons.mic, size: 24),
            label: const Text('Start Live Call', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            onPressed: () {
              ref.read(voiceCallProvider.notifier).startCall();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildScreenPane(TimPalette palette) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'What are we looking at?',
            style: TextStyle(
              color: palette.accent,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'T.I.M. can capture and analyze your active display workspace.',
            style: TextStyle(color: palette.muted, fontSize: 14),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: Colors.black,
              minimumSize: const Size(220, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            ),
            icon: const Icon(Icons.screen_share, size: 24),
            label: const Text('Scan Active Screen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            onPressed: () {
              // Send the trigger phrase to run the vision pipeline
              ref.read(chatProvider.notifier).sendText("look at my screen");
              setState(() => _activeMode = 'chat');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInputPill(ChatState chat, TimPalette palette, ModelState model) {
    if (chat.isGenerating) {
      return Container(
        height: 56,
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'T.I.M. is thinking…',
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
            const SizedBox(width: 24),
            OutlinedButton.icon(
              onPressed: () => ref.read(chatProvider.notifier).stopGeneration(),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.danger,
                side: BorderSide(color: palette.danger),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 820, maxHeight: 120),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Attachment options (+)
          PopupMenuButton<String>(
            icon: Icon(Icons.add, color: palette.textSecondary),
            tooltip: 'Add files/context',
            onSelected: (value) {
              if (value == 'context') {
                setState(() => _activeView = 'profile');
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Drag and drop files/folders directly into this window to attach them.'),
                  ),
                );
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'upload',
                child: Row(
                  children: [
                    Icon(Icons.upload_file, size: 18, color: palette.textSecondary),
                    const SizedBox(width: 12),
                    const Text('Upload files'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'folder',
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 18, color: palette.textSecondary),
                    const SizedBox(width: 12),
                    const Text('Add local folder'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'context',
                child: Row(
                  children: [
                    Icon(Icons.memory, size: 18, color: palette.textSecondary),
                    const SizedBox(width: 12),
                    const Text('Provide context block'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),

          // Message input field
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              decoration: InputDecoration(
                hintText: _dragging ? 'Drop files here…' : 'Message T.I.M. (or drag files)…',
                hintStyle: TextStyle(color: palette.muted),
                border: InputBorder.none,
                fillColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),

          // Model selector dropdown
          GestureDetector(
            onTap: () {
              showDialog<void>(
                context: context,
                builder: (_) => const ModelSelectionDialog(),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: palette.surfaceVariant,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Text(
                    model.selected?.label ?? 'Qwen3 14B',
                    style: TextStyle(color: palette.textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 16, color: palette.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Microphone / Send button
          IconButton(
            icon: Icon(
              _inputCtrl.text.trim().isNotEmpty ? Icons.send : Icons.mic,
              color: palette.textSecondary,
            ),
            onPressed: () {
              if (_inputCtrl.text.trim().isNotEmpty) {
                _send();
              } else {
                ref.read(voiceCallProvider.notifier).startCall();
              }
            },
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
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final label = state.selected?.label ?? 'Change model';

    final isReady = state.phase == ModelPhase.ready;
    final isLoading = state.phase == ModelPhase.loading || state.phase == ModelPhase.downloading;

    return ActionChip(
      avatar: isLoading
          ? const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          : Icon(
              isReady ? Icons.memory : Icons.warning_amber_rounded,
              size: 14,
              color: isReady ? palette.primary : Colors.orangeAccent,
            ),
      label: Text(
        isReady ? label : '$label (Not loaded)',
        style: TextStyle(
          color: isReady ? palette.textSecondary : Colors.orangeAccent,
          fontSize: 11,
        ),
      ),
      backgroundColor: Colors.white.withValues(alpha: 0.05),
      side: BorderSide(
        color: isReady ? Colors.white.withValues(alpha: 0.1) : Colors.orangeAccent.withValues(alpha: 0.3),
      ),
      onPressed: () {
        showDialog<void>(
          context: context,
          builder: (_) => const ModelSelectionDialog(),
        );
      },
    );
  }
}
