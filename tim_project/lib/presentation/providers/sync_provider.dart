// ============================================================
// lib/presentation/providers/sync_provider.dart
// Phase 4 — Encrypted cloud sync state.
//
// Toggle-able per user. When ON, the local vault snapshot is
// serialised + AES-256-GCM encrypted + pushed to Supabase's
// `memory_blobs` table. When OFF, the app is fully air-gapped.
// ============================================================

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/crypto_service.dart';
import '../../data/services/local_vault.dart';
import '../../data/services/supabase_service.dart';
import 'vault_provider.dart';

@immutable
class SyncState {
  const SyncState({
    this.enabled = false,
    this.lastSyncedAt,
    this.syncing = false,
    this.error,
  });
  final bool enabled;
  final DateTime? lastSyncedAt;
  final bool syncing;
  final String? error;

  SyncState copyWith({
    bool? enabled,
    DateTime? lastSyncedAt,
    bool? syncing,
    String? error,
  }) =>
      SyncState(
        enabled: enabled ?? this.enabled,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        syncing: syncing ?? this.syncing,
        error: error ?? this.error,
      );
}

class SyncController extends StateNotifier<SyncState> {
  SyncController(this._vaultGetter, this._crypto)
      : super(const SyncState()) {
    _loadPref();
  }

  final LocalVault? Function() _vaultGetter;
  final CryptoService _crypto;

  Future<void> _loadPref() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(enabled: prefs.getBool('cloud_sync') ?? false);
  }

  Future<void> toggle(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cloud_sync', on);
    state = state.copyWith(enabled: on, error: null);
  }

  /// Push an encrypted snapshot to Supabase. Requires the vault
  /// to be unlocked (i.e. the E2EE key is in memory).
  Future<void> pushNow(SecretKey key) async {
    if (!state.enabled) return;
    final vault = _vaultGetter();
    if (vault == null) {
      state = state.copyWith(error: 'Vault not unlocked');
      return;
    }
    state = state.copyWith(syncing: true, error: null);
    try {
      final snapshot = await vault.exportSnapshot();
      // NOTE: we use the same packing but a fresh salt per push.
      final salt = _crypto.newSalt();
      final cipher = await _crypto.encrypt(
        snapshot.toString(), // simplistic; production: jsonEncode
        key: key,
        salt: salt,
      );
      await SupabaseService.pushEncryptedBlob(cipher, version: 1);
      state = state.copyWith(
        syncing: false,
        lastSyncedAt: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(syncing: false, error: '$e');
    }
  }
}

final syncProvider = StateNotifierProvider<SyncController, SyncState>(
  (ref) {
    final vaultController = ref.watch(vaultProvider.notifier);
    final crypto = ref.watch(cryptoProvider);
    return SyncController(() => vaultController.vault, crypto);
  },
);
