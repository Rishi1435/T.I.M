// ============================================================
// lib/data/models/learned_rule.dart
// A Reflexion self-correction rule, written back to the vault at
// the end of a session.
// ============================================================

class LearnedRule {
  LearnedRule({
    required this.id,
    required this.summary,
    required this.priority,
    required this.createdAt,
  });

  final String id;
  final String summary;
  final double priority;
  final DateTime createdAt;
}
