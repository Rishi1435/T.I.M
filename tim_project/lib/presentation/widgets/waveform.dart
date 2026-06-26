// ============================================================
// lib/presentation/widgets/waveform.dart
// Phase 5 — Fluid audio waveform that pulses in real-time to the
// conversation's decibel levels (mimics a real phone call).
// ============================================================

import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class Waveform extends StatelessWidget {
  const Waveform({
    super.key,
    required this.samples,
    required this.level,
    this.barCount = 48,
    this.barWidth = 4.0,
    this.spacing = 3.0,
  });

  final List<double> samples; // 0..1 normalised
  final double level; // 0..1 overall decibel level
  final int barCount;
  final double barWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<TimPalette>()!;
    final bars = <double>[];
    for (var i = 0; i < barCount; i++) {
      final s = (i < samples.length ? samples[i] : 0.0);
      // Combine per-sample jitter with the overall level for the pulse.
      bars.add((s * 0.6 + level * 0.4).clamp(0.05, 1.0));
    }
    return SizedBox(
      height: 80,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final b in bars) ...[
            Container(
              width: barWidth,
              height: 8 + b * 72,
              decoration: BoxDecoration(
                color: Color.lerp(palette.primary, palette.accent, b),
                borderRadius: BorderRadius.circular(barWidth / 2),
              ),
            ),
            SizedBox(width: spacing),
          ],
        ],
      ),
    );
  }
}


