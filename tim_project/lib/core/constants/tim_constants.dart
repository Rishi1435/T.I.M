// ============================================================
// lib/core/constants/tim_constants.dart
// Single source of truth for cross-cutting magic values.
// ============================================================

class TimConstants {
  TimConstants._();

  /// MethodChannel name for the native hardware scanner.
  static const String hardwareChannel = 'tim.hardware/scanner';

  /// Local SQLite vault filename (lives in app support dir).
  static const String vaultDbName = 'tim_vault.sqlite';

  /// .tim backup file magic header (used by tim_backup.dart).
  static const String backupMagic = 'TIMCOREv1';

  /// PBKDF2 iteration count for deriving the E2EE key from the
  /// master password. 200k is the OWASP 2023 minimum for SHA-256.
  static const int pbkdf2Iterations = 200000;

  /// AES-256-GCM key length in bytes.
  static const int aesKeyLenBytes = 32;

  /// Embedding dimension used by sqlite-vec. Matches the local
  /// embedding model the LLM engine exposes (e.g. bge-small-en 384).
  /// Override via --dart-define=EMB_DIM=... if you swap models.
  static const int embeddingDim =
      int.fromEnvironment('EMB_DIM', defaultValue: 384);

  /// Voice biometric enrolment sentence (read for 10 seconds).
  static const String enrolmentSentence =
      'My voice is my passport. Verify me. T.I.M. listens for this '
      'vocal footprint and ignores anyone else who speaks.';
}
