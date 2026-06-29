// ============================================================
// lib/presentation/screens/settings_screen.dart
// View pane: system preferences configuration.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/sync_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final syncState = ref.watch(syncProvider);
    final syncCtrl = ref.read(syncProvider.notifier);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SingleChildScrollView(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Text(
                  'System Preferences',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Configure hardware profiling and offline security measures.',
                  style: TextStyle(color: palette.textSecondary, fontSize: 15),
                ),
                const SizedBox(height: 40),

                // Local Engine & Hardware
                _buildCard(
                  title: 'Local Engine & Hardware',
                  palette: palette,
                  children: [
                    _buildSettingRow(
                      title: 'Dynamic Hardware Profiling',
                      description:
                          'T.I.M. auto-scales models based on physical RAM and battery power state (e.g., swapping to Qwen2.5 3B when unplugged) to prevent OS lag.',
                      value: true,
                      onChanged: (val) {},
                      palette: palette,
                    ),
                    _buildSettingRow(
                      title: 'Air-Gapped Mode',
                      description:
                          'Sever all Supabase cloud sync completely. All RAG vectors and interaction metadata remain secured locally via SQLite + sqlite-vec.',
                      value: !syncState.enabled,
                      onChanged: (val) {
                        syncCtrl.toggle(!val);
                      },
                      palette: palette,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Voice Mode & Biometrics
                _buildCard(
                  title: 'Voice Mode & Biometrics',
                  palette: palette,
                  children: [
                    _buildSettingRow(
                      title: 'ECAPA-TDNN Voice Lock',
                      description:
                          'Biometric scanner matches your vocal footprint during playback. Ignores background noise and halts the AI only when you speak.',
                      value: true,
                      onChanged: (val) {},
                      palette: palette,
                    ),
                    _buildSettingRow(
                      title: 'Cadence Mentorship Interruption',
                      description:
                          'Speech analytics track timestamps between words. T.I.M. will interrupt to correct your cadence if air gaps exceed 2.5 seconds.',
                      value: true,
                      onChanged: (val) {},
                      palette: palette,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required TimPalette palette,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 16),
          ...children.expand((w) => [
                w,
                if (w != children.last)
                  Divider(
                    color: Colors.white.withValues(alpha: 0.1),
                    height: 32,
                  ),
              ]),
        ],
      ),
    );
  }

  Widget _buildSettingRow({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    required TimPalette palette,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 13,
                  color: palette.muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        Switch.adaptive(
          value: value,
          onChanged: onChanged,
          activeColor: palette.primary,
        ),
      ],
    );
  }
}
