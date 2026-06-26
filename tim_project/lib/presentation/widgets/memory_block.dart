// ============================================================
// lib/presentation/widgets/memory_block.dart
// Phase 3 — A Memory Block card shown during Genesis onboarding.
// User can edit, delete, or toggle confirmation before persistence.
// ============================================================

import 'package:flutter/material.dart';
import '../providers/onboarding_provider.dart';

class MemoryBlockCard extends StatelessWidget {
  const MemoryBlockCard({
    super.key,
    required this.block,
    required this.onToggleConfirm,
    required this.onDelete,
    required this.onEdit,
  });

  final MemoryBlock block;
  final VoidCallback onToggleConfirm;
  final VoidCallback onDelete;
  final ValueChanged<String> onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: block.confirmed
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(
                    block.category,
                    style: const TextStyle(fontSize: 11),
                  ),
                  padding: EdgeInsets.zero,
                ),
                const Spacer(),
                IconButton(
                  tooltip: block.confirmed
                      ? 'Unconfirm'
                      : 'Confirm',
                  icon: Icon(
                    block.confirmed
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: block.confirmed
                        ? Colors.green
                        : Colors.grey,
                  ),
                  onPressed: onToggleConfirm,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Colors.redAccent,
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: block.content,
              maxLines: null,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
              ),
              style: theme.textTheme.bodyMedium,
              onChanged: onEdit,
            ),
          ],
        ),
      ),
    );
  }
}
