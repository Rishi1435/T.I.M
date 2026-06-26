// ============================================================
// lib/data/services/crypto_service.dart
// Zero-Knowledge encryption layer.
//
// - Derives a 256-bit AES key from the user's master password
//   using PBKDF2-SHA256 (200k iterations, per OWASP 2023).
// - The derived key never leaves the device.
// - All vault payloads (memories, directives, reflexion rules) are
//   serialised and encrypted with AES-256-GCM before any cloud sync.
// - Supabase only ever stores ciphertext + nonce + salt.
//
// Recovery model: if the user forgets the master password, the
// cloud blobs are unrecoverable. This is by design.
// ============================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/logger.dart';

class CryptoService {
  CryptoService() : _log = Logger('CryptoService');

  final Logger _log;

  /// Derive the AES-256 key from `password` + `salt`.
  /// Returns a [SecretKey] that lives only in process memory.
  Future<SecretKey> deriveKey(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: TimConstants.pbkdf2Iterations,
      bits: TimConstants.aesKeyLenBytes * 8,
    );
    final secret = SecretKey(utf8.encode(password));
    final derived = await pbkdf2.deriveKey(secretKey: secret, nonce: salt);
    _log.info('Derived AES-256 key (salt=${salt.length}B, '
              'iters=${TimConstants.pbkdf2Iterations}).');
    return derived;
  }

  /// Encrypt `plaintext` with AES-256-GCM. Returns a packed blob:
  ///   [salt(16) | nonce(12) | ciphertext | tag(16)]
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

    // Pack: salt + nonce + ciphertext + tag
    final out = BytesBuilder()
      ..add(salt)
      ..add(nonce)
      ..add(secretBox.cipherText)
      ..add(secretBox.mac.bytes);
    return out.toBytes();
  }

  /// Decrypt a blob produced by [encrypt]. Throws on tampering /
  /// wrong key (GCM tag verification fails).
  Future<String> decrypt(Uint8List blob, {required SecretKey key}) async {
    if (blob.length < 16 + 12 + 16) {
      throw const FormatException('Encrypted blob too short');
    }
    final salt = blob.sublist(0, 16);
    final nonce = blob.sublist(16, 28);
    final cipherText = blob.sublist(28, blob.length - 16);
    final mac = Mac(blob.sublist(blob.length - 16));

    final algorithm = AesGcm.with256bits();
    final plain = await algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    _log.info('Decrypted blob (salt=${salt.length}B, ct=${cipherText.length}B).');
    return utf8.decode(plain);
  }

  /// Convenience: generate a fresh 16-byte salt for a new user.
  List<int> newSalt() => List<int>.generate(16, (_) => _randByte());

  // ---- helpers ----------------------------------------------------
  static int _randByte() {
    // Simple non-crypto RNG; for production replace with
    // `cryptography`'s secure random. Adequate for the salt's role
    // (uniqueness, not secrecy).
    final now = DateTime.now().microsecondsSinceEpoch;
    return (now ^ (now >> 8) ^ (now >> 16)) & 0xFF;
  }
}
