// ============================================================
// lib/presentation/screens/home_screen.dart
// Overhauled home screen: collapsible sidebar navigation,
// radial gradient background, view-pane switcher, mode switcher,
// and premium chat input pill.
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/file_chip.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
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
    _dictationSub?.cancel();
    _dictationRecorder.dispose();
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
    final model = ref.watch(modelProvider);
    final voice = ref.watch(voiceCallProvider);
    final onboardingDone = ref.watch(onboardingCompletedProvider);
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    // v0.3.4: hardware stats moved to Vault Settings ("This computer").
    // Passing an empty string hides the sidebar block entirely.
    const hardwareInfo = '';

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
                        _showNewSessionDialog(context);
                      },
                      onWorkspaceSelected: (workspace) {
                        setState(() {
                          _activeView = 'home';
                          _activeMode = 'chat';
                        });
                        ref.read(chatProvider.notifier).changeWorkspace(workspace);
                      },
                      workspaces: ref.watch(chatProvider.notifier).getWorkspaces(),
                      activeWorkspace: chat.activeWorkspace,
                      hardwareInfo: hardwareInfo,
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
            'Screen sharing is passive: T.I.M. snapshots your screen only '
            'at the moment you ask. Say or type "look at my screen…" with '
            'your question — from chat or during a Live Call — and it '
            'reads what you\'re working on right then.',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 14, height: 1.5),
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
            label: const Text('Ask about my screen now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
            onSelected: (value) async {
              // v0.3.4: these menu items now actually work.
              final chatCtrl = ref.read(chatProvider.notifier);
              if (value == 'upload') {
                final files = await openFiles();
                for (final f in files) {
                  final len = await f.length();
                  chatCtrl.addFileChip(FileChip(
                    id: DateTime.now().microsecondsSinceEpoch.toString() +
                        f.name,
                    name: f.name,
                    kind: FileChip.inferKind(f.name),
                    sizeBytes: len,
                    localUri: f.path,
                  ));
                }
              } else if (value == 'folder') {
                final dir = await getDirectoryPath();
                if (dir != null) {
                  chatCtrl.addFileChip(FileChip(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    name: dir.split(Platform.pathSeparator).last,
                    kind: FileChipKind.unknown,
                    sizeBytes: 0,
                    localUri: dir,
                  ));
                }
              } else if (value == 'context') {
                _showContextBlockDialog(context);
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

          // Microphone (dictate into the text box) / Send button.
          // v0.3.4: the mic no longer hijacks you into Live Call —
          // tap to dictate, tap again to stop; the transcript lands
          // in the input box for you to edit and send.
          IconButton(
            tooltip: _dictating
                ? 'Stop dictation'
                : (_inputCtrl.text.trim().isNotEmpty
                    ? 'Send'
                    : 'Dictate into the message box'),
            icon: Icon(
              _inputCtrl.text.trim().isNotEmpty && !_dictating
                  ? Icons.send
                  : (_dictating ? Icons.stop_circle : Icons.mic),
              color: _dictating ? palette.danger : palette.textSecondary,
            ),
            onPressed: () {
              if (_dictating) {
                _stopDictation();
              } else if (_inputCtrl.text.trim().isNotEmpty) {
                _send();
              } else {
                _startDictation();
              }
            },
          ),
          const SizedBox(height: 14),
          // v0.3.9 — Copilot-style continuous sharing: no trigger
          // phrase needed while ON; every question carries the screen.
          TextButton.icon(
            icon: Icon(
              ref.read(chatProvider.notifier).screenShareActive
                  ? Icons.stop_screen_share_outlined
                  : Icons.screen_share_outlined,
              size: 18,
            ),
            label: Text(
              ref.read(chatProvider.notifier).screenShareActive
                  ? 'Stop sharing my screen'
                  : 'Start sharing my screen (auto-attach to every question)',
            ),
            onPressed: () => setState(
                () => ref.read(chatProvider.notifier).toggleScreenShare()),
          ),
        ],
      ),
    );
  }

  // ---- v0.3.4 chat-box dictation ------------------------------
  final AudioRecorder _dictationRecorder = AudioRecorder();
  bool _dictating = false;
  final List<int> _dictationBuffer = [];
  StreamSubscription<Uint8List>? _dictationSub;

  Future<void> _startDictation() async {
    if (_dictating) return;
    if (!await _dictationRecorder.hasPermission()) return;
    _dictationBuffer.clear();
    final stream = await _dictationRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _dictationSub = stream.listen(_dictationBuffer.addAll);
    setState(() => _dictating = true);
  }

  Future<void> _stopDictation() async {
    await _dictationSub?.cancel();
    _dictationSub = null;
    await _dictationRecorder.stop();
    setState(() => _dictating = false);
    final pcm = Uint8List.fromList(_dictationBuffer);
    _dictationBuffer.clear();
    if (pcm.isEmpty) return;
    final worker = ref.read(timWorkerProvider);
    final text = await worker.transcribeOnce(pcm);
    if (text.isNotEmpty && mounted) {
      final existing = _inputCtrl.text.trim();
      setState(() {
        _inputCtrl.text = existing.isEmpty ? text : '$existing $text';
        _inputCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _inputCtrl.text.length),
        );
      });
    }
  }

  void _showContextBlockDialog(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text('Context block',
            style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            maxLines: 6,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText:
                  'Paste any background T.I.M. should consider for the next message…',
              hintStyle: TextStyle(color: palette.muted),
            ),
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                Text('Cancel', style: TextStyle(color: palette.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) {
                ref.read(chatProvider.notifier).addFileChip(FileChip(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      name: v.length > 24 ? '${v.substring(0, 21)}…' : v,
                      kind: FileChipKind.text,
                      sizeBytes: v.length,
                      localUri: '',
                      metadata: {'text': v},
                    ));
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('Attach'),
          ),
        ],
      ),
    );
  }

  void _showNewSessionDialog(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final controller = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text('Create New Session', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter session name (e.g. Code Review)',
            hintStyle: TextStyle(color: palette.muted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: palette.primary),
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: palette.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final name = controller.text.trim();
              // v0.3.4: name is optional — an unnamed session starts
              // blank and titles itself from your first message.
              ref
                  .read(chatProvider.notifier)
                  .changeWorkspace(name.isNotEmpty ? name : 'New Chat');
              Navigator.of(ctx).pop();
            },
            child: const Text('Create', style: TextStyle(fontWeight: FontWeight.bold)),
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
