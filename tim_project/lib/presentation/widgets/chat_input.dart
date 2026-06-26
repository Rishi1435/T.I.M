// ============================================================
// lib/presentation/widgets/chat_input.dart
// Bottom chat dock: text field + send button + mic toggle +
// drag-and-drop target. Files dropped here turn into chips.
// ============================================================

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/file_chip.dart';
import '../providers/chat_provider.dart';

class ChatInput extends ConsumerStatefulWidget {
  const ChatInput({super.key, required this.onSend});
  final ValueChanged<String> onSend;

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends ConsumerState<ChatInput> {
  final _ctrl = TextEditingController();
  bool _micOn = false;
  bool _dragging = false;

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (details) {
        for (final f in details.files) {
          final chip = FileChip(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: f.name,
            kind: FileChip.inferKind(f.name),
            sizeBytes: 0, // populate via File.stat in production
            localUri: f.path,
          );
          ref.read(chatProvider.notifier).addFileChip(chip);
        }
      },
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          border: Border.all(
            color: _dragging
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Voice mode',
              icon: Icon(
                _micOn ? Icons.mic : Icons.mic_none,
                color: _micOn ? Colors.redAccent : null,
              ),
              onPressed: () => setState(() => _micOn = !_micOn),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                  hintText: _dragging
                      ? 'Drop files to attach…'
                      : 'Message T.I.M. (or drag files in)…',
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.send, size: 18),
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }
}
