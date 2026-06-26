// ============================================================
// lib/data/services/tim_backup.dart
// Phase 4 — Air-gapped "Export T.I.M. Core" backup.
//
// Produces an encrypted .tim file containing the full vault snapshot.
// The file format is:
//   [magic 9B "TIMCOREv1"]
//   [salt 16B]
//   [nonce 12B]
//   [ciphertext+tag]   (AES-256-GCM of the JSON snapshot)
//
// Recovery requires the master password. Without it, the .tim file is
// unreadable gibberish — by design.
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/logger.dart';
import 'crypto_service.dart';
import 'local_vault.dart';

class TimBackup {
  TimBackup(this._crypto) : _log = Logger('TimBackup');

  final CryptoService _crypto;
  final Logger _log;

  /// Export [vault] to an encrypted .tim file. Returns the file path.
  Future<String> export(LocalVault vault, String masterPassword) async {
    final snapshot = await vault.exportSnapshot();
    final json = jsonEncode(snapshot);
    final salt = _crypto.newSalt();
    final key = await _crypto.deriveKey(masterPassword, salt);
    final cipher = await _crypto.encrypt(json, key: key, salt: salt);

    // Pack: magic + salt + nonce + ciphertext+tag (already packed by encrypt).
    final out = BytesBuilder()
      ..add(utf8.encode(TimConstants.backupMagic))
      ..add(salt)
      ..add(cipher);

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final path = p.join(dir.path, 'T.I.M.-$ts.tim');
    await File(path).writeAsBytes(out.toBytes());
    _log.info('Exported encrypted backup: $path (${out.length}B)');
    return path;
  }

  /// Import an encrypted .tim file into [vault]. Throws on bad password
  /// (GCM tag verification fails) or corrupt file.
  Future<Map<String, dynamic>> import(
    String path,
    String masterPassword,
  ) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 9 + 16 + 28 + 16) {
      throw const FormatException('.tim file too short');
    }
    final magic = utf8.decode(bytes.sublist(0, 9));
    if (magic != TimConstants.backupMagic) {
      throw FormatException('Bad magic: $magic (expected '
                            '${TimConstants.backupMagic})');
    }
    final salt = bytes.sublist(9, 25);
    final cipher = bytes.sublist(25);
    final key = await _crypto.deriveKey(masterPassword, salt);
    final json = await _crypto.decrypt(Uint8List.fromList(cipher), key: key);
    final snapshot = jsonDecode(json) as Map<String, dynamic>;
    _log.info('Imported .tim snapshot (version ${snapshot['version']}).');
    return snapshot;
  }
}
