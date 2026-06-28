// ============================================================
// lib/presentation/widgets/message_bubble.dart
// Gemini-style chat bubbles:
//   • AI  — left-aligned, no background, copy button on hover,
//            pulsing "•••" while empty/streaming, blinking cursor.
//   • User — right-aligned pill, copy button on hover.
//   • System — centred muted caption.
// ============================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import 'file_chip_row.dart';

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
  });
  final ChatMessage message;
  /// True when this is the message currently being written by the LLM.
  final bool isStreaming;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _copied = false;
  Timer? _copyTimer;

  // Blinking cursor animation
  late final AnimationController _cursorCtrl;
  late final Animation<double> _cursorOpacity;

  // Thinking dots animation (three dots cycling)
  late Timer _dotTimer;
  int _dotCount = 1;

  @override
  void initState() {
    super.initState();
    _cursorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 530),
    )..repeat(reverse: true);
    _cursorOpacity = _cursorCtrl.drive(CurveTween(curve: Curves.easeInOut));

    _dotTimer = Timer.periodic(const Duration(milliseconds: 420), (_) {
      if (mounted) setState(() => _dotCount = (_dotCount % 3) + 1);
    });
  }

  @override
  void dispose() {
    _cursorCtrl.dispose();
    _dotTimer.cancel();
    _copyTimer?.cancel();
    super.dispose();
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isUser   = widget.message.sender == MessageSender.user;
    final isSystem = widget.message.sender == MessageSender.system;
    final theme    = Theme.of(context);
    final text     = widget.message.text;

    if (isSystem) return _SystemCaption(text: text);
    if (isUser)   return _UserBubble(message: widget.message, onCopy: _copy, copied: _copied, hovered: _hovered, onHover: (v) => setState(() => _hovered = v));

    // ── AI bubble ──────────────────────────────────────────────
    final isEmpty   = text.isEmpty;
    final isStream  = widget.isStreaming;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar circle
            Container(
              width: 32,
              height: 32,
              margin: const EdgeInsets.only(top: 2, right: 12),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF8AB4F8), Color(0xFFE8C3F5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Center(
                child: Text('T', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black)),
              ),
            ),

            // Message body
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // "T.I.M." label
                  Text(
                    'T.I.M.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: const Color(0xFF8AB4F8),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Content: thinking dots OR streamed text + cursor
                  if (isEmpty && isStream)
                    _ThinkingDots(dotCount: _dotCount)
                  else
                    _AiTextContent(
                      text: text,
                      isStreaming: isStream,
                      cursorOpacity: _cursorOpacity,
                    ),

                  // Action row (copy) on hover
                  if (!isEmpty) ...[
                    const SizedBox(height: 6),
                    AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: _CopyButton(copied: _copied, onTap: () => _copy(text)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Thinking dots ──────────────────────────────────────────────────────────
class _ThinkingDots extends StatelessWidget {
  const _ThinkingDots({required this.dotCount});
  final int dotCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (i) {
        final active = i < dotCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(right: 4),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? const Color(0xFF8AB4F8)
                : const Color(0xFF8AB4F8).withValues(alpha: 0.3),
          ),
        );
      }),
    );
  }
}

// ── AI text with optional blinking cursor ─────────────────────────────────
class _AiTextContent extends StatelessWidget {
  const _AiTextContent({
    required this.text,
    required this.isStreaming,
    required this.cursorOpacity,
  });
  final String text;
  final bool isStreaming;
  final Animation<double> cursorOpacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.6,
    );

    if (!isStreaming) {
      return SelectableText(
        text,
        style: baseStyle,
        textWidthBasis: TextWidthBasis.parent,
      );
    }

    // While streaming: plain Text + animated cursor so layout doesn't jump
    return RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: text),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: FadeTransition(
              opacity: cursorOpacity,
              child: Container(
                width: 2,
                height: 16,
                margin: const EdgeInsets.only(left: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF8AB4F8),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Copy button ───────────────────────────────────────────────────────────
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.copied, required this.onTap});
  final bool copied;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: copied
              ? const Color(0xFF81C995).withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: copied
                ? const Color(0xFF81C995).withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 13,
              color: copied ? const Color(0xFF81C995) : const Color(0xFF9AA0A6),
            ),
            const SizedBox(width: 4),
            Text(
              copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 11,
                color: copied ? const Color(0xFF81C995) : const Color(0xFF9AA0A6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── User bubble ───────────────────────────────────────────────────────────
class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.message,
    required this.onCopy,
    required this.copied,
    required this.hovered,
    required this.onHover,
  });
  final ChatMessage message;
  final void Function(String) onCopy;
  final bool copied;
  final bool hovered;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (message.attachments.isNotEmpty) ...[
              FileChipRow(chips: message.attachments),
              const SizedBox(height: 6),
            ],
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.55,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A5F),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
                border: Border.all(color: const Color(0xFF2A5298).withValues(alpha: 0.5)),
              ),
              child: SelectableText(
                message.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  height: 1.5,
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: hovered ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _CopyButton(copied: copied, onTap: () => onCopy(message.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── System caption ────────────────────────────────────────────────────────
class _SystemCaption extends StatelessWidget {
  const _SystemCaption({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF5F6368),
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}
