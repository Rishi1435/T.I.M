// ============================================================
// lib/presentation/widgets/sidebar.dart
// Redesigned premium collapsible sidebar.
// ============================================================

import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.activeView,
    required this.onViewChanged,
    required this.onNewSession,
    required this.onWorkspaceSelected,
    required this.workspaces,
    required this.activeWorkspace,
    required this.hardwareInfo,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final String activeView;
  final ValueChanged<String> onViewChanged;
  final VoidCallback onNewSession;
  final ValueChanged<String> onWorkspaceSelected;
  final List<String> workspaces;
  final String activeWorkspace;
  final String hardwareInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<TimPalette>()!;

    final content = Column(
      children: [
        // Collapsible trigger
        _buildNavItem(
          icon: Icons.menu,
          label: 'Collapse',
          isActive: false,
          onTap: onToggle,
          palette: palette,
        ),
        const SizedBox(height: 16),

        // New Session button
        _buildNavItem(
          icon: Icons.add,
          label: 'New session',
          isActive: false, // Don't highlight New Session persistently
          onTap: () {
            onViewChanged('home');
            onNewSession();
          },
          palette: palette,
        ),

        // History Section
        if (expanded) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent Workspaces'.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: workspaces.length,
              itemBuilder: (context, index) {
                final ws = workspaces[index];
                final isCurrent = ws == activeWorkspace && activeView == 'home';
                IconData icon;
                if (ws.toLowerCase().contains('planning')) {
                  icon = Icons.chat_bubble_outline;
                } else if (ws.toLowerCase().contains('interview')) {
                  icon = Icons.graphic_eq;
                } else if (ws.toLowerCase().contains('config') || ws.toLowerCase().contains('api')) {
                  icon = Icons.code;
                } else {
                  icon = Icons.folder_open_outlined;
                }
                return _buildHistoryItem(
                  icon: icon,
                  label: ws,
                  onTap: () => onWorkspaceSelected(ws),
                  palette: palette,
                  isActive: isCurrent,
                );
              },
            ),
          ),
        ] else
          const Spacer(),

        // Bottom items
        _buildNavItem(
          icon: Icons.storage,
          label: 'Memory Vault',
          isActive: activeView == 'profile',
          onTap: () => onViewChanged('profile'),
          palette: palette,
        ),
        _buildNavItem(
          icon: Icons.settings,
          label: 'Vault Settings',
          isActive: activeView == 'settings',
          onTap: () => onViewChanged('settings'),
          palette: palette,
        ),
        if (expanded && hardwareInfo.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(color: Colors.white10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SYSTEM HARDWARE',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: palette.muted,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  hardwareInfo,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );

    // Glassmorphic translucent styling when expanded, transparent when collapsed
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: expanded ? const Color(0xDA0F1115) : Colors.transparent,
        border: Border(
          right: BorderSide(
            color: expanded ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
          ),
        ),
      ),
      child: expanded
          ? ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: content,
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: content,
            ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
    required TimPalette palette,
  }) {
    return Tooltip(
      message: expanded ? '' : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: EdgeInsets.symmetric(horizontal: expanded ? 14 : 11),
          decoration: BoxDecoration(
            color: isActive ? palette.surfaceVariant : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: isActive ? palette.primary : palette.textSecondary,
              ),
              if (expanded) ...[
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isActive ? palette.primary : palette.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required TimPalette palette,
    required bool isActive,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        color: isActive ? palette.primary.withValues(alpha: 0.1) : Colors.transparent,
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive ? palette.primary : palette.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isActive ? palette.primary : palette.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
