// ============================================================
// lib/presentation/widgets/voice_indicator.dart
// Compact pill that shows the current voice-mode state.
// ============================================================

import 'package:flutter/material.dart';
import '../providers/chat_provider.dart';

class VoiceIndicator extends StatelessWidget {
  const VoiceIndicator({super.key, required this.state});
  final VoiceState state;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (state) {
      VoiceState.listening =>
        ('Listening…', Colors.green, Icons.mic),
      VoiceState.verifying =>
        ('Verifying voiceprint…', Colors.amber, Icons.shield),
      VoiceState.speaking =>
        ('Speaking…', Colors.blue, Icons.volume_up),
      VoiceState.idle => ('Idle', Colors.grey, Icons.mic_none),
    };
    return Align(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
