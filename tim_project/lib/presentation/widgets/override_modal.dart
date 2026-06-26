// ============================================================
// lib/presentation/widgets/override_modal.dart
// Phase 2 — Safety override modal.
//
// Shown when the user manually selects a model that violates the
// hardware profile (e.g. forcing 14B on battery). Lists the risks
// and requires explicit confirmation.
// ============================================================

import 'package:flutter/material.dart';

class OverrideModal extends StatelessWidget {
  const OverrideModal({super.key, required this.onConfirm});

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(
        Icons.warning_amber_rounded,
        size: 48,
        color: Colors.amber,
      ),
      title: const Text('Override hardware recommendation?'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You\'re asking T.I.M. to load a model that exceeds the '
               'current hardware profile.'),
          SizedBox(height: 12),
          Text('Risks:', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('• Severe battery depletion (possibly > 30 %/hr)'),
          Text('• OS lag / input latency while the model is loaded'),
          Text('• Possible OOM crash if RAM is insufficient'),
          Text('• Thermal throttling on laptops without active cooling'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            foregroundColor: Colors.amber,
          ),
          onPressed: () {
            Navigator.of(context).pop();
            onConfirm();
          },
          child: const Text('I understand — proceed'),
        ),
      ],
    );
  }
}
