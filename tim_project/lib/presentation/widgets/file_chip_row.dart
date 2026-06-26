// ============================================================
// lib/presentation/widgets/file_chip_row.dart
// Renders a horizontal list of FileChip thumbnails above the chat
// input. Each chip is dismissable.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/file_chip.dart';
import '../providers/chat_provider.dart';

class FileChipRow extends ConsumerWidget {
  const FileChipRow({super.key, required this.chips});
  final List<FileChip> chips;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = chips[i];
          return Chip(
            avatar: Icon(_iconFor(c.kind), size: 16),
            label: Text(c.name),
            onDeleted: () => ref
                .read(chatProvider.notifier)
                .removeFileChip(c.id),
          );
        },
      ),
    );
  }

  static IconData _iconFor(FileChipKind k) {
    return switch (k) {
      FileChipKind.pdf => Icons.picture_as_pdf,
      FileChipKind.image => Icons.image,
      FileChipKind.video => Icons.movie,
      FileChipKind.audio => Icons.audiotrack,
      FileChipKind.text => Icons.description,
      FileChipKind.unknown => Icons.attach_file,
    };
  }
}


