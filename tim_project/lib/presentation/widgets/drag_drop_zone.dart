// ============================================================
// lib/presentation/widgets/drag_drop_zone.dart
// Universal drag-and-drop target used on the Genesis screen.
// Accepts PDFs / images / MP4s / text files. Calls [onText] for
// text content, [onFile] for binary paths.
// ============================================================

import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

class DragDropZone extends StatefulWidget {
  const DragDropZone({
    super.key,
    required this.onText,
    required this.onFile,
  });

  final ValueChanged<String> onText;
  final ValueChanged<String> onFile;

  @override
  State<DragDropZone> createState() => _DragDropZoneState();
}

class _DragDropZoneState extends State<DragDropZone> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (details) {
        setState(() => _hover = false);
        for (final f in details.files) {
          final lower = f.name.toLowerCase();
          if (lower.endsWith('.txt') ||
              lower.endsWith('.md') ||
              lower.endsWith('.dart') ||
              lower.endsWith('.py')) {
            // Text files: read synchronously (small).
            try {
              final bytes = File(f.path).readAsBytesSync();
              final text = utf8.decode(bytes);
              widget.onText(text);
            } catch (_) {
              widget.onFile(f.path);
            }
          } else {
            widget.onFile(f.path);
          }
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 180,
        decoration: BoxDecoration(
          border: Border.all(
            color: _hover
                ? Theme.of(context).colorScheme.primary
                : Colors.white24,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(16),
          color: _hover
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.upload_file,
                  size: 36,
                  color: _hover
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
              ),
              const SizedBox(height: 8),
              const Text('Drop resume, images, MP4s, or text files'),
              const SizedBox(height: 4),
              const Text(
                '(PDFs parsed locally — never uploaded)',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
