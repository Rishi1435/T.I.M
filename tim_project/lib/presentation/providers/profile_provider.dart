// ============================================================
// lib/presentation/providers/profile_provider.dart
// Manage user memory blocks (data with T.I.M.) securely.
// ============================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/memory.dart';
import '../../data/services/local_vault.dart';
import '../../data/services/llm_engine.dart';
import 'vault_provider.dart';

class ProfileState {
  const ProfileState({
    this.memories = const [],
    this.loading = false,
    this.error,
  });

  final List<Memory> memories;
  final bool loading;
  final String? error;

  ProfileState copyWith({
    List<Memory>? memories,
    bool? loading,
    String? error,
  }) {
    return ProfileState(
      memories: memories ?? this.memories,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

class ProfileController extends StateNotifier<ProfileState> {
  ProfileController(this._vaultGetter) : super(const ProfileState()) {
    loadMemories();
  }

  final LocalVault? Function() _vaultGetter;

  Future<void> loadMemories() async {
    final vault = _vaultGetter();
    if (vault == null) {
      state = state.copyWith(error: 'Vault not unlocked');
      return;
    }
    state = state.copyWith(loading: true, error: null);
    try {
      final list = await vault.listRecent(limit: 500);
      state = state.copyWith(memories: list, loading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), loading: false);
    }
  }

  Future<void> deleteMemory(String id) async {
    final vault = _vaultGetter();
    if (vault == null) return;
    try {
      vault.deleteMemory(id);
      state = state.copyWith(
        memories: state.memories.where((m) => m.id != id).toList(),
      );
    } catch (e) {
      state = state.copyWith(error: 'Failed to delete memory: $e');
    }
  }

  Future<void> editMemory(String id, String content) async {
    final vault = _vaultGetter();
    if (vault == null) return;
    try {
      final emb = LlmEngine.hashEmbed(content);
      vault.updateMemory(id, content, emb);
      state = state.copyWith(
        memories: state.memories.map((m) {
          if (m.id == id) {
            return Memory(
              id: m.id,
              userId: m.userId,
              content: content,
              metadata: m.metadata,
              createdAt: m.createdAt,
              embedding: emb,
            );
          }
          return m;
        }).toList(),
      );
    } catch (e) {
      state = state.copyWith(error: 'Failed to edit memory: $e');
    }
  }

  Future<void> addMemory(String content, String category) async {
    final vault = _vaultGetter();
    if (vault == null) return;
    try {
      final emb = LlmEngine.hashEmbed(content);
      final newMemory = await vault.insertMemory(
        content: content,
        metadata: {'category': category, 'source': 'manual'},
        embedding: emb,
      );
      state = state.copyWith(
        memories: [newMemory, ...state.memories],
      );
    } catch (e) {
      state = state.copyWith(error: 'Failed to add memory: $e');
    }
  }
}

final profileProvider =
    StateNotifierProvider<ProfileController, ProfileState>((ref) {
  final vaultController = ref.watch(vaultProvider.notifier);
  return ProfileController(() => vaultController.vault);
});
