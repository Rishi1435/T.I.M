// ============================================================
// lib/presentation/screens/settings_screen.dart
// View pane: system preferences configuration.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/app_settings_provider.dart';
import '../providers/hardware_provider.dart';
import '../providers/sync_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;
    final syncState = ref.watch(syncProvider);
    final syncCtrl = ref.read(syncProvider.notifier);
    final settings = ref.watch(appSettingsProvider);
    final settingsCtrl = ref.read(appSettingsProvider.notifier);
    final hw = ref.watch(hardwareProvider);

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
                      title: 'Match AI to my computer',
                      description:
                          'Automatically picks a lighter AI model when your PC is low on memory or running on battery, so the rest of your system stays fast.',
                      value: settings.hardwareProfiling,
                      onChanged: settingsCtrl.setHardwareProfiling,
                      palette: palette,
                    ),
                    _buildSettingRow(
                      title: 'Offline-only mode',
                      description:
                          'Keep everything on this computer and never sync to the cloud. Your encrypted backup stays local until you turn this off.',
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
                      title: 'Respond only to my voice',
                      description:
                          'During calls, T.I.M. pauses when it hears you speak and ignores other voices, TV, or background noise. Needs a one-time 10-second voice enrollment.',
                      value: settings.voiceLock,
                      onChanged: settingsCtrl.setVoiceLock,
                      palette: palette,
                    ),
                    _buildSettingRow(
                      title: 'Speaking-pace coaching',
                      description:
                          'If you pause too long or use lots of filler words while practicing, T.I.M. jumps in with a tip to tighten your delivery.',
                      value: settings.cadenceCoaching,
                      onChanged: settingsCtrl.setCadenceCoaching,
                      palette: palette,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                _buildCard(
                  title: 'Behavior',
                  palette: palette,
                  children: [
                    _buildSettingRow(
                      title: 'Start each launch with a fresh chat',
                      description:
                          'Open T.I.M. to a clean new session instead of your previous conversation. Older sessions stay in the sidebar.',
                      value: settings.openFreshSessionOnLaunch,
                      onChanged: settingsCtrl.setOpenFreshSessionOnLaunch,
                      palette: palette,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Moved out of the sidebar (v0.3.4): hardware details are
                // reference info, not something to stare at all day.
                _buildCard(
                  title: 'This computer',
                  palette: palette,
                  children: [
                    Text(
                      hw.maybeWhen(
                        data: (p) =>
                            'RAM: ${p.totalRamGb.toStringAsFixed(0)} GB   ·   '
                            'VRAM: ${p.dedicatedVramGb.toStringAsFixed(0)} GB\n'
                            'GPU: ${p.gpuName}\n'
                            'Power: ${p.batteryStatusString}',
                        orElse: () => 'Detecting hardware…',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: palette.textSecondary,
                      ),
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
