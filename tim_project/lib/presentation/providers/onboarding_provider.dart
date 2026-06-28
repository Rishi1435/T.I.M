// ============================================================
// lib/presentation/providers/onboarding_provider.dart
// Phase 3 — Genesis onboarding state machine.
//
// States:
//   blank    -> T.I.M. introduces itself ("I don't know your story yet.")
//   drafting -> resume dropped; LLM extracting draft Memory Blocks
//   review   -> user edits / deletes / adds blocks
//   confirmed-> vectorise + persist into the local vault
// ============================================================

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/local_vault.dart';
import '../../data/services/llm_engine.dart';
import 'model_provider.dart';
import 'vault_provider.dart';

enum GenesisPhase { blank, drafting, review, confirmed }

@immutable
class MemoryBlock {
  const MemoryBlock({
    required this.draftId,
    required this.category,
    required this.content,
    this.metadata = const {},
    this.confirmed = false,
  });
  final String draftId;
  final String category; // 'academic' | 'professional' | 'project' | ...
  final String content;
  final Map<String, dynamic> metadata;
  final bool confirmed;

  MemoryBlock copyWith({
    String? content,
    Map<String, dynamic>? metadata,
    bool? confirmed,
  }) =>
      MemoryBlock(
        draftId: draftId,
        category: category,
        content: content ?? this.content,
        metadata: metadata ?? this.metadata,
        confirmed: confirmed ?? this.confirmed,
      );
}

@immutable
class GenesisState {
  const GenesisState({
    this.phase = GenesisPhase.blank,
    this.blocks = const [],
    this.extracting = false,
    this.error,
  });
  final GenesisPhase phase;
  final List<MemoryBlock> blocks;
  final bool extracting;
  final String? error;

  GenesisState copyWith({
    GenesisPhase? phase,
    List<MemoryBlock>? blocks,
    bool? extracting,
    String? error,
  }) =>
      GenesisState(
        phase: phase ?? this.phase,
        blocks: blocks ?? this.blocks,
        extracting: extracting ?? this.extracting,
        error: error,
      );
}

class GenesisController extends StateNotifier<GenesisState> {
  GenesisController(this._vault, this._llm)
      : super(const GenesisState());

  final LocalVault? Function() _vault;
  final LlmEngine _llm;

  /// Called when the user drops a resume (PDF text). Sends the text
  /// to the LLM and asks it to extract draft Memory Blocks.
  Future<void> extractFromResume(String resumeText) async {
    // Guard: model must be loaded before we can generate.
    if (!_llm.isLoaded) {
      state = state.copyWith(
        phase: GenesisPhase.blank,
        error: 'No AI model loaded yet. Please download a model first.',
      );
      return;
    }
    state = state.copyWith(phase: GenesisPhase.drafting, extracting: true, error: null);
    final prompt = '''
You are T.I.M.'s Genesis extractor. Given the resume below, extract
factual memory blocks. Output STRICT JSON: a list of objects with
{ "category", "content", "metadata" }. Categories: academic, professional,
project, skill. Do NOT invent facts. If unsure, omit.

RESUME:
$resumeText
''';
    try {
      final buf = StringBuffer();
      await for (final tok in _llm.generate(prompt, maxTokens: 800)) {
        buf.write(tok);
      }
      final blocks = _parseBlocks(buf.toString());
      state = state.copyWith(
        phase: GenesisPhase.review,
        blocks: blocks,
        extracting: false,
      );
    } catch (e) {
      state = state.copyWith(
        phase: GenesisPhase.blank,
        extracting: false,
        error: 'Extraction failed: $e',
      );
    }
  }

  /// Manually add a Memory Block (user types it themselves).
  void addBlock(MemoryBlock b) {
    state = state.copyWith(blocks: [...state.blocks, b]);
  }

  /// Edit a block's content.
  void editBlock(String draftId, String content) {
    state = state.copyWith(
      blocks: state.blocks
          .map((b) => b.draftId == draftId ? b.copyWith(content: content) : b)
          .toList(),
    );
  }

  /// Confirm / un-confirm a block.
  void toggleConfirm(String draftId) {
    state = state.copyWith(
      blocks: state.blocks
          .map((b) => b.draftId == draftId
              ? b.copyWith(confirmed: !b.confirmed)
              : b,)
          .toList(),
    );
  }

  /// Delete a block.
  void deleteBlock(String draftId) {
    state = state.copyWith(
      blocks: state.blocks.where((b) => b.draftId != draftId).toList(),
    );
  }

  /// Confirm-all: vectorise the confirmed blocks into the local vault.
  Future<void> confirmAll() async {
    final vault = _vault();
    if (vault == null) {
      state = state.copyWith(
        error: 'Vault not unlocked. Please log out and sign in again.',
      );
      return;
    }
    state = state.copyWith(phase: GenesisPhase.confirmed);
    try {
      for (final b in state.blocks.where((b) => b.confirmed)) {
        final emb = await _llm.embed(b.content);
        await vault.insertMemory(
          content: b.content,
          metadata: {
            'category': b.category,
            ...b.metadata,
            'source': 'genesis',
          },
          embedding: emb,
        );
      }
    } catch (e) {
      state = state.copyWith(
        phase: GenesisPhase.review,
        error: 'Onboarding verification failed: $e',
      );
    }
  }

  // ---- helpers ---------------------------------------------------
  List<MemoryBlock> _parseBlocks(String llmOutput) {
    // Tolerant JSON extraction: pull the first [...] block.
    final start = llmOutput.indexOf('[');
    final end = llmOutput.lastIndexOf(']');
    if (start < 0 || end < 0) return [];
    final jsonStr = llmOutput.substring(start, end + 1);
    try {
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      return list.asMap().entries.map((e) => MemoryBlock(
            draftId: 'draft-${e.key}',
            category: e.value['category'] as String? ?? 'general',
            content: e.value['content'] as String? ?? '',
            metadata: (e.value['metadata'] as Map?)?.cast<String, dynamic>() ??
                const {},
            confirmed: true,
          ),).toList();
    } catch (_) {
      return [];
    }
  }
}

final genesisProvider =
    StateNotifierProvider<GenesisController, GenesisState>(
  (ref) {
    final vaultController = ref.watch(vaultProvider.notifier);
    final llm = ref.watch(llmEngineProvider);
    return GenesisController(
      () => vaultController.vault,
      llm,
    );
  },
);
