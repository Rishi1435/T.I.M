// ============================================================
// lib/data/models/file_chip.dart
// Visual chip rendered in the chat input dock when the user drags
// a file in (PDF / image / MP4 / etc.).
// ============================================================

enum FileChipKind { pdf, image, video, audio, text, unknown }

class FileChip {
  FileChip({
    required this.id,
    required this.name,
    required this.kind,
    required this.sizeBytes,
    required this.localUri,
    this.metadata = const {},
  });

  final String id;
  final String name;
  final FileChipKind kind;
  final int sizeBytes;
  final String localUri;
  final Map<String, dynamic> metadata;

  static FileChipKind inferKind(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return FileChipKind.pdf;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv')) {
      return FileChipKind.video;
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      return FileChipKind.image;
    }
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a')) {
      return FileChipKind.audio;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.dart') ||
        lower.endsWith('.py')) {
      return FileChipKind.text;
    }
    return FileChipKind.unknown;
  }
}
