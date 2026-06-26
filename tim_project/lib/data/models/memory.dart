// ============================================================
// lib/data/models/memory.dart
// PODO mirroring the `memories` table in the local SQLite vault.
// ============================================================

class Memory {
  Memory({
    required this.id,
    required this.userId,
    required this.content,
    required this.metadata,
    required this.createdAt,
    this.embedding,
  });

  final String id;
  final String userId;
  final String content;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final List<double>? embedding;

  factory Memory.fromRow(Map<String, dynamic> row) {
    return Memory(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      content: row['content'] as String,
      metadata: (row['metadata'] as Map).cast<String, dynamic>(),
      createdAt: DateTime.parse(row['created_at'] as String),
      embedding: (row['embedding'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
    );
  }
}
