// ============================================================
// lib/data/services/attachment_reader.dart
// v0.4.2 — the missing bridge between attached chips and the LLM.
//
// Confirmed bug (screenshot: folder attached, user asks "tell me
// what are there in the files", T.I.M. asks "what files?"): chips
// were pure UI — no code path ever read attachment CONTENT into the
// prompt. This service is that path, and it is deliberately shared
// with Diagnostics so "attachments reach the model" is a testable
// claim, not an assumption.
//
// Supported: plain text / code / md / json / csv (up to ~6 KB per
// file), PDFs via syncfusion text extraction, folder chips (entry
// listing + small text files inside), and context-block chips
// (metadata['text']).
// ============================================================

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../core/utils/logger.dart';
import '../models/file_chip.dart';

class AttachmentReader {
  static final Logger _log = Logger('AttachmentReader');

  // v0.4.3 — sized for the REAL context window. 16K chars (~4K
  // tokens) overflowed the model's nCtx=4096 the moment history and
  // the system prompt were added, killing generations instantly.
  static const int _perFileCap = 3500; // chars
  static const int _totalCap = 7000; // chars across all chips

  static const _textExts = {
    '.txt', '.md', '.dart', '.py', '.js', '.ts', '.json', '.yaml', '.yml',
    '.csv', '.html', '.css', '.xml', '.sql', '.sh', '.ps1', '.bat', '.log',
    '.ini', '.toml', '.gitignore', '.env.example', '.java', '.kt', '.cpp',
    '.c', '.h', '.rs', '.go',
  };

  /// Build a prompt-ready context block from the chips. Empty string
  /// when there is nothing readable.
  static Future<String> read(List<FileChip> chips) async {
    if (chips.isEmpty) return '';
    final b = StringBuffer();
    var total = 0;

    void addSection(String header, String body) {
      if (total >= _totalCap || body.trim().isEmpty) return;
      final clipped = body.length > _perFileCap
          ? '${body.substring(0, _perFileCap)}\n…[truncated]'
          : body;
      b.writeln('--- $header ---');
      b.writeln(clipped);
      total += clipped.length;
    }

    for (final chip in chips) {
      try {
        // Context blocks carry their text inline.
        if (chip.metadata['text'] is String &&
            (chip.metadata['text'] as String).trim().isNotEmpty) {
          addSection('Context block: ${chip.name}',
              chip.metadata['text'] as String);
          continue;
        }
        if (chip.localUri.isEmpty) continue;

        final entityType = FileSystemEntity.typeSync(chip.localUri);
        if (entityType == FileSystemEntityType.directory) {
          addSection('Attached folder: ${chip.name}',
              await _readFolder(chip.localUri));
        } else if (entityType == FileSystemEntityType.file) {
          addSection(
              'Attached file: ${chip.name}', await _readFile(chip.localUri));
        }
      } catch (e) {
        _log.warn('Could not read attachment ${chip.name}: $e');
        addSection('Attached: ${chip.name}',
            '<could not read: $e>');
      }
    }
    if (b.isEmpty) return '';
    return '\n[Files the user attached to this message]\n$b';
  }

  static Future<String> _readFile(String path) async {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.pdf') {
      final bytes = await File(path).readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);
      try {
        return PdfTextExtractor(doc).extractText();
      } finally {
        doc.dispose();
      }
    }
    if (_textExts.contains(ext) || ext.isEmpty) {
      return File(path).readAsString();
    }
    final size = File(path).lengthSync();
    return '<binary file, ${(size / 1024).toStringAsFixed(0)} KB — '
        'content type not readable as text>';
  }

  static Future<String> _readFolder(String dirPath) async {
    final dir = Directory(dirPath);
    final entries = dir.listSync(followLinks: false);
    final b = StringBuffer('Folder contains ${entries.length} entries:\n');
    for (final e in entries.take(40)) {
      final name = p.basename(e.path);
      b.writeln(e is Directory ? '  [dir] $name' : '  $name');
    }
    // Pull content of up to 3 small text files for real substance.
    var pulled = 0;
    for (final e in entries.whereType<File>()) {
      if (pulled >= 3) break;
      final ext = p.extension(e.path).toLowerCase();
      if (_textExts.contains(ext) && e.lengthSync() < 40 * 1024) {
        try {
          b.writeln('\n-- ${p.basename(e.path)} --');
          final content = await e.readAsString();
          b.writeln(content.length > 2000
              ? '${content.substring(0, 2000)}\n…[truncated]'
              : content);
          pulled++;
        } catch (_) {}
      }
    }
    return b.toString();
  }
}
