// ============================================================
// lib/data/services/supabase_service.dart
// Thin accessor around the Supabase singleton. Centralised so the
// rest of the codebase never touches the global directly.
//
// Supabase is used for TWO things only:
//   1. Multi-tenant auth (owner / wife / sister / friends).
//   2. Encrypted blob sync — `memory_blobs` table stores ONLY
//      ciphertext produced by CryptoService. Supabase never sees
//      plaintext. Recovery requires the user's master password.
// ============================================================

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  const SupabaseService._();

  static SupabaseClient get client => Supabase.instance.client;
  static User? get currentUser => client.auth.currentUser;
  static Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  /// Convenience: the active user id, or empty string when signed out.
  static String get currentUserId => currentUser?.id ?? '';
  static String get currentUserEmail => currentUser?.email ?? '';

  // ---- Encrypted blob sync ---------------------------------------

  /// Push an encrypted blob to the user's row in `memory_blobs`.
  /// `blob` is the packed AES-256-GCM ciphertext from CryptoService.
  static Future<void> pushEncryptedBlob(
    Uint8List blob, {
    required int version,
  }) async {
    await client.from('memory_blobs').upsert({
      'user_id': currentUserId,
      'blob': blob,
      'version': version,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Pull the latest encrypted blob (returns null if none).
  static Future<({Uint8List blob, int version})?> pullEncryptedBlob() async {
    final row = await client
        .from('memory_blobs')
        .select('blob, version')
        .eq('user_id', currentUserId)
        .maybeSingle();
    if (row == null) return null;
    final blob = (row['blob'] as List).cast<int>();
    return (blob: Uint8List.fromList(blob), version: row['version'] as int);
  }
}
