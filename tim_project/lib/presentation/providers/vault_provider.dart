// ============================================================
// lib/presentation/providers/vault_provider.dart
// Owns the LocalVault + CryptoService lifecycle for the signed-in
// user. Vault is "unlocked" only after the master password is
// provided (which derives the E2EE key).
// ============================================================

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/crypto_service.dart';
import '../../data/services/local_vault.dart';
import '../../data/services/supabase_service.dart';

enum VaultState { locked, unlocking, unlocked, error }

class VaultController extends StateNotifier<VaultState> {
  VaultController(this._crypto) : super(VaultState.locked);

  final CryptoService _crypto;
  LocalVault? _vault;
  SecretKey? _key;

  LocalVault? get vault => _vault;
  SecretKey? get key => _key;
  bool get isUnlocked => state == VaultState.unlocked;

  /// Unlock the vault for the current Supabase user. Derives the E2EE
  /// key from `masterPassword`, opens SQLite, loads sqlite-vec.
  Future<void> unlock(String masterPassword) async {
    state = VaultState.unlocking;
    try {
      final userId = SupabaseService.currentUserId;
      if (userId.isEmpty) {
        throw StateError('No authenticated user');
      }
      _vault = LocalVault(userId: userId);
      await _vault!.open();
      // Derive the E2EE key deterministically from the user's UUID for device/session consistency.
      final salt = utf8.encode(userId.replaceAll('-', '')).sublist(0, 16);
      _key = await _crypto.deriveKey(masterPassword, salt);
      state = VaultState.unlocked;
    } catch (e) {
      state = VaultState.error;
      rethrow;
    }
  }

  void lock() {
    _vault?.dispose();
    _vault = null;
    _key = null;
    state = VaultState.locked;
  }

  @override
  void dispose() {
    _vault?.dispose();
    super.dispose();
  }
}

final cryptoProvider = Provider<CryptoService>((ref) => CryptoService());

final vaultProvider =
    StateNotifierProvider<VaultController, VaultState>(
  (ref) => VaultController(ref.read(cryptoProvider)),
);
