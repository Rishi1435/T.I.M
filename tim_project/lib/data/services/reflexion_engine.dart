// ============================================================
// lib/data/services/reflexion_engine.dart
// Phase 7 — Reflexion self-correction.
//
// At the end of a session, T.I.M. summarises the mistakes the user
// made (e.g. "User struggled to explain Agentic AI clearly today"),
// writes this "learned rule" back into the vault with high priority,
// and adjusts future system prompts to drill on those weaknesses.
// ============================================================

import '../../core/utils/logger.dart';
import 'local_vault.dart';
import 'llm_engine.dart';

class ReflexionEngine {
  ReflexionEngine(this._vault, this._llm)
      : _log = Logger('ReflexionEngine');

  final LocalVault _vault;
  final LlmEngine _llm;
  final Logger _log;

  /// Summarise a session transcript and persist the learned rule.
  ///
  /// [transcript] is the full chat + voice transcript for the session.
  /// The LLM is asked to identify ONE weakness and phrase it as an
  /// actionable drilling rule.
  Future<String> summariseAndPersist(String transcript) async {
    if (transcript.trim().isEmpty) {
      return '<empty session — nothing to reflect on>';
    }

    _log.info('Reflexion: summarising ${transcript.length} chars.');
    final prompt = '''
You are T.I.M.'s reflexion module. Review the session transcript below.
Identify ONE concrete communication or technical weakness the user
exhibited. Phrase it as a terse drilling rule (e.g. "User struggled to
explain Agentic AI clearly — drill the definition + 1 analogy next session").
Return ONLY the rule, no preamble.

TRANSCRIPT:
$transcript
''';

    final buf = StringBuffer();
    await for (final tok in _llm.generate(prompt, maxTokens: 80)) {
      buf.write(tok);
    }
    final rule = buf.toString().trim();
    _log.info('Reflexion rule: $rule');

    // Persist with high priority so it bubbles up in future system prompts.
    final emb = await _llm.embed(rule);
    await _vault.addReflexionRule(
      summary: rule,
      priority: 2.0,
      embedding: emb,
    );

    return rule;
  }

  /// Build the system-prompt preamble that biases the next session
  /// toward drilling the user's top weaknesses.
  Future<String> drillPreamble({int topK = 3}) async {
    final rules = await _vault.topReflexionRules(k: topK);
    if (rules.isEmpty) return '';
    final bullets = rules
        .map((r) => '- ${r['summary']} (priority ${r['priority']})')
        .join('\n');
    return '''
DRILL FOCUS (from Reflexion):
The user has shown these weaknesses. When relevant, surface drills:
$bullets
''';
  }
}
