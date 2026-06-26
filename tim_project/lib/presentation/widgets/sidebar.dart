// ============================================================
// lib/presentation/widgets/sidebar.dart
// Collapsible Gemini-style sidebar. Houses conversation history,
// project shortcuts, and the "new chat" affordance.
// ============================================================

import 'package:flutter/material.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(expanded ? Icons.menu_open : Icons.menu),
                  onPressed: onToggle,
                ),
                if (expanded) ...[
                  const SizedBox(width: 8),
                  Text(
                    'T.I.M.',
                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                  ),
                ],
              ],
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New chat'),
                  onPressed: () {},
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {},
              ),
            ),
          const Divider(),
          if (expanded)
            ListTile(
              dense: true,
              leading: const Icon(Icons.work_outline, size: 18),
              title: const Text('Xpensia'),
              onTap: () {},
            ),
          if (expanded)
            ListTile(
              dense: true,
              leading: const Icon(Icons.mic_none, size: 18),
              title: const Text('Q-L-U-E'),
              subtitle: const Text(
                'pronounced "clue"',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              onTap: () {},
            ),
          const Spacer(),
          if (expanded)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Local-first • E2EE • pgvector-free',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}
