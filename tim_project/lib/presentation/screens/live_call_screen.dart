// ============================================================
// lib/presentation/screens/live_call_screen.dart
// Phase 5 — full-screen Live Call overlay.
//
// When voice mode is active, the chat UI fades away and this ambient
// overlay takes over: a fluid audio waveform pulses in real-time to
// the conversation's decibel levels, mimicking a real phone call.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glass_kit/glass_kit.dart';

import '../providers/voice_provider.dart';
import '../widgets/waveform.dart';

class LiveCallView extends ConsumerWidget {
  const LiveCallView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceCallProvider);
    return Stack(
      children: [
        // Ambient gradient backdrop
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                Color.fromRGBO(0x8A, 0xB4, 0xF8, 0.15 + voice.decibel * 0.15),
                Colors.black87,
              ],
              radius: 0.8,
            ),
          ),
        ),
        // Glassy centre panel with the waveform
        Center(
          child: GlassContainer.frostedGlass(
            height: 320,
            width: 480,
            blur: 24,
            color: Colors.white.withValues(alpha: 0.06),
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.10),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
            borderGradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.20),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    voice.active ? 'T.I.M. — Live Call' : 'Idle',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Waveform(samples: voice.waveform, level: voice.decibel),
                  const SizedBox(height: 24),
                  if (voice.interruptionMessage != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        voice.interruptionMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.amber),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filled(
                        icon: const Icon(Icons.mic_off),
                        onPressed: () => ref
                            .read(voiceCallProvider.notifier)
                            .stopCall(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
