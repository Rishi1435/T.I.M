// ============================================================
// lib/data/services/crypto_service.dart
// Zero-Knowledge encryption layer — v2 (Path B security fixes).
//
// Changes vs v1:
//   1. KDF upgraded PBKDF2 → Argon2id (memory-hard; GPU/ASIC
//      resistant). Legacy v1 blobs still decrypt via the PBKDF2
//      fallback, and are transparently re-encrypted on next save.
//   2. FIXED a real bug: v1's salt generator derived all 16 bytes
//      from the same microsecond timestamp, producing near-constant
//      salts. Salts now come from Random.secure().
//   3. Blob format is versioned:
//        v2: [0x54 0x02 | salt(16) | nonce(12) | ct | tag(16)]
//        v1: [salt(16) | nonce(12) | ct | tag(16)]   (no magic)
//
// Recovery model unchanged: forget the master password and the
// cloud blobs are unrecoverable — surface the printable recovery
// key at onboarding (tracked in genesis_screen TODO).
// ============================================================

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/logger.dart';

class CryptoService {
  CryptoService() : _log = Logger('CryptoService');

  final Logger _log;

  static const int _magic0 = 0x54; // 'T'
  static const int _versionV2 = 0x02;

  /// Argon2id parameters (OWASP 2024 "moderate" profile, tuned for
  /// an 8GB laptop: 64 MiB memory, 3 passes, 2 lanes).
  static Argon2id _argon2() => Argon2id(
        memory: 64 * 1024, // KiB
        parallelism: 2,
        iterations: 3,
        hashLength: TimConstants.aesKeyLenBytes,
      );

  /// Derive the AES-256 key from `password` + `salt` (Argon2id).
  Future<SecretKey> deriveKey(String password, List<int> salt) async {
    final derived = await _argon2().deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    _log.info('Derived AES-256 key via Argon2id '
        '(64MiB, t=3, p=2, salt=${salt.length}B).');
    return derived;
  }

  /// Legacy KDF for v1 blobs only. Do not use for new data.
  Future<SecretKey> deriveKeyLegacyPbkdf2(
      String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: TimConstants.pbkdf2Iterations,
      bits: TimConstants.aesKeyLenBytes * 8,
    );
    return pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }

  /// Encrypt `plaintext` with AES-256-GCM. Returns a v2 packed blob:
  ///   [0x54 0x02 | salt(16) | nonce(12) | ciphertext | tag(16)]
  Future<Uint8List> encrypt(
    String plaintext, {
    required SecretKey key,
    required List<int> salt,
  }) async {
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    final out = BytesBuilder()
      ..add(const [_magic0, _versionV2])
      ..add(salt)
      ..add(nonce)
      ..add(secretBox.cipherText)
      ..add(secretBox.mac.bytes);
    return out.toBytes();
  }

  /// True if [blob] is the new versioned format.
  static bool isV2(Uint8List blob) =>
      blob.length > 2 && blob[0] == _magic0 && blob[1] == _versionV2;

  /// Decrypt a v2 or legacy v1 blob. For v1, pass the password so
  /// the legacy PBKDF2 key can be derived from the embedded salt.
  /// Throws on tampering / wrong key (GCM tag verification fails).
  Future<String> decrypt(
    Uint8List blob, {
    required SecretKey key,
    String? passwordForLegacy,
  }) async {
    final v2 = isV2(blob);
    final body = v2 ? Uint8List.sublistView(blob, 2) : blob;
    if (body.length < 16 + 12 + 16) {
      throw const FormatException('Encrypted blob too short');
    }
    final salt = body.sublist(0, 16);
    final nonce = body.sublist(16, 28);
    final cipherText = body.sublist(28, body.length - 16);
    final mac = Mac(body.sublist(body.length - 16));
    final box = SecretBox(cipherText, nonce: nonce, mac: mac);
    final algorithm = AesGcm.with256bits();

    SecretKey useKey = key;
    if (!v2 && passwordForLegacy != null) {
      useKey = await deriveKeyLegacyPbkdf2(passwordForLegacy, salt);
      _log.info('Legacy v1 blob detected — PBKDF2 fallback. '
          'Re-encrypt on next save.');
    }
    final plain = await algorithm.decrypt(box, secretKey: useKey);
    return utf8.decode(plain);
  }

  /// Cryptographically random 16-byte salt.
  List<int> newSalt() {
    final rng = Random.secure();
    return List<int>.generate(16, (_) => rng.nextInt(256));
  }
}
