// ============================================================
// lib/data/services/local_vault.dart
// The Local Vault — 100% offline RAG store.
//
// Stack:
//   - sqlite3 + sqlite3_flutter_libs for the relational store.
//   - sqlite-vec virtual table for KNN over embeddings.
//
// Schema:
//   memories(id, content, metadata_json, created_at, embedding BLOB)
//   directives(id, type, content, metadata_json, active, created_at)
//   reflexion_rules(id, summary, priority, created_at, embedding BLOB)
//   voice_prints(id, label, embedding BLOB, created_at)
//   file_chips(id, kind, name, blob_uri, metadata_json, created_at)
//
// All embeddings are stored as raw little-endian f32 vectors of length
// TimConstants.embeddingDim. sqlite-vec's vec0 virtual table provides
// cosine / L2 KNN.
//
// The vault is per-user and lives at:
//   <app_support_dir>/vault/<user_id>/tim_vault.sqlite
// ============================================================

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/constants/tim_constants.dart';
import '../../core/utils/logger.dart';
import '../models/memory.dart';

class LocalVault {
  LocalVault({required this.userId}) : _log = Logger('LocalVault');

  final String userId;
  final Logger _log;
  Database? _db;
  bool _vecAvailable = false;

  /// Open (or create) the vault for [userId]. Idempotent.
  Future<void> open() async {
    if (_db != null) return;
    final dir = await _vaultDir();
    await dir.create(recursive: true);
    final path = p.join(dir.path, TimConstants.vaultDbName);
    _log.info('Opening vault at $path');
    _db = sqlite3.open(path);
    _loadVecExtension();
    _migrate();
  }

  Future<Directory> _vaultDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'vault', userId));
  }

  void _migrate() {
    final db = _db!;
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');

    // Relational tables.
    db.execute('''
      CREATE TABLE IF NOT EXISTS memories (
        id            TEXT PRIMARY KEY,
        content       TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        created_at    TEXT NOT NULL DEFAULT (datetime('now')),
        embedding     BLOB
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS directives (
        id            TEXT PRIMARY KEY,
        type          TEXT NOT NULL,
        content       TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        active        INTEGER NOT NULL DEFAULT 1,
        created_at    TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS reflexion_rules (
        id            TEXT PRIMARY KEY,
        summary       TEXT NOT NULL,
        priority      REAL NOT NULL DEFAULT 1.0,
        created_at    TEXT NOT NULL DEFAULT (datetime('now')),
        embedding     BLOB
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS voice_prints (
        id            TEXT PRIMARY KEY,
        label         TEXT NOT NULL,
        embedding     BLOB NOT NULL,
        created_at    TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS file_chips (
        id            TEXT PRIMARY KEY,
        kind          TEXT NOT NULL,
        name          TEXT NOT NULL,
        blob_uri      TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        created_at    TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');

    // ── Chat history ────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id          TEXT PRIMARY KEY,
        sender      TEXT NOT NULL,
        text        TEXT NOT NULL,
        workspace   TEXT NOT NULL DEFAULT 'General',
        created_at  TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    try {
      db.execute("ALTER TABLE chat_messages ADD COLUMN workspace TEXT NOT NULL DEFAULT 'General';");
    } catch (_) {}

    // sqlite-vec virtual table for memories.
    // vec0 stores a rowid + a fixed-dim float vector.
    if (_vecAvailable) {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_vec
        USING vec0(embedding float[${TimConstants.embeddingDim}]);
      ''');
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS reflexion_vec
        USING vec0(embedding float[${TimConstants.embeddingDim}]);
      ''');
    }
  }

  void _loadVecExtension() {
    try {
      final library = DynamicLibrary.open('vec0.dll');
      sqlite3.ensureExtensionLoaded(
        SqliteExtension.inLibrary(library, 'sqlite3_vec_init'),
      );
      _vecAvailable = true;
      _log.info('sqlite-vec extension loaded.');
    } catch (e) {
      _vecAvailable = false;
      _log.warn('sqlite-vec extension not available ($e). '
                'Semantic search will be disabled until vec0.dll is provisioned.');
    }
  }

  // ============================================================
  // Memories CRUD
  // ============================================================
  Future<Memory> insertMemory({
    required String content,
    Map<String, dynamic> metadata = const {},
    List<double>? embedding,
  }) async {
    print('DEBUG [LocalVault]: Attempting to insert memory. Content length=${content.length}');
    try {
      final db = _db!;
      final id = _uuid();
      final emb = _encodeEmbedding(embedding);
      db.prepare('''
        INSERT INTO memories (id, content, metadata_json, embedding)
        VALUES (?, ?, ?, ?)
      ''').execute([id, content, jsonEncode(metadata), emb]);

      if (embedding != null && _vecAvailable) {
        db.prepare('INSERT INTO memories_vec(rowid, embedding) VALUES (?, ?)')
            .execute([db.lastInsertRowId, emb]);
      }
      print('DEBUG [LocalVault]: Successfully inserted memory id=$id');
      return Memory(
        id: id,
        userId: userId,
        content: content,
        metadata: metadata,
        createdAt: DateTime.now(),
        embedding: embedding,
      );
    } catch (e) {
      print('CRITICAL [LocalVault]: Failed to insert memory - $e');
      rethrow;
    }
  }

  Future<List<Memory>> listRecent({int limit = 50}) async {
    final rows = _db!.prepare(
      'SELECT id, content, metadata_json, created_at FROM memories '
      'ORDER BY created_at DESC LIMIT ?',
    ).select([limit]);
    return rows.map(_rowToMemory).toList();
  }

  /// KNN semantic search via sqlite-vec.
  Future<List<Memory>> semanticSearch(
    List<double> queryEmbedding, {
    String? workspace,
    int k = 8,
  }) async {
    if (!_vecAvailable) {
      return listRecent(limit: k);
    }
    final emb = _encodeEmbedding(queryEmbedding);
    try {
      if (workspace != null && workspace.isNotEmpty) {
        final rows = _db!.prepare('''
          SELECT m.id, m.content, m.metadata_json, m.created_at
          FROM memories_vec v
          JOIN memories m ON m.rowid = v.rowid
          WHERE v.embedding MATCH ? AND json_extract(m.metadata_json, '\$.workspace') = ?
          ORDER BY v.distance
          LIMIT ?
        ''').select([emb, workspace, k]);
        if (rows.isNotEmpty) {
          return rows.map(_rowToMemory).toList();
        }
      }
      final rows = _db!.prepare('''
        SELECT m.id, m.content, m.metadata_json, m.created_at
        FROM memories_vec v
        JOIN memories m ON m.rowid = v.rowid
        WHERE v.embedding MATCH ?
        ORDER BY v.distance
        LIMIT ?
      ''').select([emb, k]);
      return rows.map(_rowToMemory).toList();
    } catch (e) {
      _log.warn('vec KNN failed ($e); falling back to recent.');
      return listRecent(limit: k);
    }
  }

  /// Delete a memory by id, clearing it from memories and memories_vec tables.
  void deleteMemory(String id) {
    print('DEBUG [LocalVault]: Attempting to delete memory id=$id');
    try {
      if (_vecAvailable) {
        try {
          _db!.prepare('DELETE FROM memories_vec WHERE rowid = (SELECT rowid FROM memories WHERE id = ?)')
              .execute([id]);
        } catch (e) {
          _log.warn('Failed to delete from memories_vec: $e');
        }
      }
      _db!.prepare('DELETE FROM memories WHERE id = ?').execute([id]);
      print('DEBUG [LocalVault]: Successfully deleted memory id=$id');
    } catch (e) {
      print('CRITICAL [LocalVault]: Failed to delete memory - $e');
      rethrow;
    }
  }

  /// Update a memory content and optionally its embedding vector.
  void updateMemory(String id, String content, List<double>? embedding) {
    print('DEBUG [LocalVault]: Attempting to update memory id=$id');
    try {
      final emb = _encodeEmbedding(embedding);
      _db!.prepare('UPDATE memories SET content = ?, embedding = ? WHERE id = ?')
          .execute([content, emb, id]);
      if (embedding != null && _vecAvailable) {
        try {
          _db!.prepare('UPDATE memories_vec SET embedding = ? WHERE rowid = (SELECT rowid FROM memories WHERE id = ?)')
              .execute([emb, id]);
        } catch (e) {
          _log.warn('Failed to update memories_vec: $e');
        }
      }
      print('DEBUG [LocalVault]: Successfully updated memory id=$id');
    } catch (e) {
      print('CRITICAL [LocalVault]: Failed to update memory - $e');
      rethrow;
    }
  }


  // ============================================================
  // Chat history
  // ============================================================

  /// Persist a single chat message to disk.
  void insertChatMessage({
    required String id,
    required String sender, // 'user' | 'ai' | 'system'
    required String text,
    required String workspace,
  }) {
    print('DEBUG [LocalVault]: Attempting to insert chat message: id=$id, sender=$sender, workspace=$workspace');
    try {
      _db!.prepare('''
        INSERT OR IGNORE INTO chat_messages (id, sender, text, workspace)
        VALUES (?, ?, ?, ?)
      ''').execute([id, sender, text, workspace]);
      print('DEBUG [LocalVault]: Successfully inserted/ignored chat message: id=$id');
    } catch (e) {
      print('CRITICAL [LocalVault]: Failed to insert chat message - $e');
      rethrow;
    }
  }

  /// Load the most recent [limit] chat messages ordered oldest-first.
  List<Map<String, String>> loadChatHistory({required String workspace, int limit = 100}) {
    final rows = _db!.prepare('''
      SELECT id, sender, text, created_at FROM chat_messages 
      WHERE workspace = ?
      ORDER BY created_at DESC LIMIT ?
    ''').select([workspace, limit]);
    // Reverse so oldest is first
    return rows.reversed
        .map((r) => {
              'id': r['id'] as String,
              'sender': r['sender'] as String,
              'text': r['text'] as String,
            },)
        .toList();
  }

  /// Rename a session/workspace (v0.3.4 auto-titling).
  void renameWorkspace(String oldName, String newName) {
    if (_db == null || oldName == newName || newName.trim().isEmpty) return;
    _db!
        .prepare('UPDATE chat_messages SET workspace = ? WHERE workspace = ?')
        .execute([newName, oldName]);
  }

  /// Load list of all unique workspaces in database.
  List<String> getWorkspaces() {
    if (_db == null) return const [];
    try {
      final stmt = _db!.prepare('''
        SELECT DISTINCT workspace FROM chat_messages 
        ORDER BY created_at DESC
      ''');
      final cursor = stmt.select();
      final List<String> list = [];
      for (final row in cursor) {
        final name = row['workspace'] as String?;
        if (name != null && name.isNotEmpty) {
          list.add(name);
        }
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  // ============================================================
  // Directives CRUD
  // ============================================================
  Future<void> upsertDirective({
    required String type,
    required String content,
    Map<String, dynamic> metadata = const {},
    bool active = true,
  }) async {
    final id = _uuid();
    _db!.prepare('''
      INSERT INTO directives (id, type, content, metadata_json, active)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        content = excluded.content,
        metadata_json = excluded.metadata_json,
        active = excluded.active
    ''').execute([id, type, content, jsonEncode(metadata), active ? 1 : 0]);
  }

  Future<List<Map<String, dynamic>>> activeDirectives() async {
    final rows = _db!.prepare(
      "SELECT type, content, metadata_json FROM directives WHERE active = 1",
    ).select([]);
    return rows
        .map(
          (r) => {
            'type': r['type'] as String,
            'content': r['content'] as String,
            'metadata': jsonDecode(r['metadata_json'] as String),
          },
        )
        .toList();
  }

  // ============================================================
  // Reflexion rules CRUD (self-correction loop)
  // ============================================================
  Future<void> addReflexionRule({
    required String summary,
    double priority = 1.0,
    List<double>? embedding,
  }) async {
    final id = _uuid();
    final emb = _encodeEmbedding(embedding);
    _db!.prepare('''
      INSERT INTO reflexion_rules (id, summary, priority, embedding)
      VALUES (?, ?, ?, ?)
    ''').execute([id, summary, priority, emb]);
    if (embedding != null && _vecAvailable) {
      _db!.prepare('INSERT INTO reflexion_vec(rowid, embedding) VALUES (?, ?)')
          .execute([_db!.lastInsertRowId, emb]);
    }
  }

  Future<List<Map<String, dynamic>>> topReflexionRules({int k = 5}) async {
    final rows = _db!.prepare(
      'SELECT summary, priority FROM reflexion_rules '
      'ORDER BY priority DESC, created_at DESC LIMIT ?',
    ).select([k]);
    return rows
        .map(
          (r) => {
            'summary': r['summary'] as String,
            'priority': (r['priority'] as num).toDouble(),
          },
        )
        .toList();
  }

  // ============================================================
  // Voice prints (biometric barge-in)
  // ============================================================
  Future<void> storeVoicePrint(
    List<double> embedding, {
    String label = 'owner',
  }) async {
    final id = _uuid();
    _db!.prepare('''
      INSERT INTO voice_prints (id, label, embedding)
      VALUES (?, ?, ?)
    ''').execute([id, label, _encodeEmbedding(embedding)]);
  }

  Future<List<double>?> loadOwnerVoicePrint() async {
    final rows = _db!.prepare(
      "SELECT embedding FROM voice_prints WHERE label = 'owner' LIMIT 1",
    ).select([]);
    if (rows.isEmpty) return null;
    return _decodeEmbedding(rows.first['embedding'] as Uint8List);
  }

  // ============================================================
  // File chips (drag-and-drop uploads)
  // ============================================================
  Future<void> storeFileChip({
    required String kind,
    required String name,
    required String blobUri,
    Map<String, dynamic> metadata = const {},
  }) async {
    final id = _uuid();
    _db!.prepare('''
      INSERT INTO file_chips (id, kind, name, blob_uri, metadata_json)
      VALUES (?, ?, ?, ?, ?)
    ''').execute([id, kind, name, blobUri, jsonEncode(metadata)]);
  }

  // ============================================================
  // Snapshot / restore (for .tim backup)
  // ============================================================
  Future<Map<String, dynamic>> exportSnapshot() async {
    final memories = _db!.prepare('SELECT * FROM memories').select([]);
    final directives = _db!.prepare('SELECT * FROM directives').select([]);
    final reflexion = _db!.prepare('SELECT * FROM reflexion_rules').select([]);
    final voiceprints = _db!.prepare('SELECT * FROM voice_prints').select([]);
    final chips = _db!.prepare('SELECT * FROM file_chips').select([]);
    return {
      'version': 1,
      'user_id': userId,
      'memories': memories,
      'directives': directives,
      'reflexion_rules': reflexion,
      'voice_prints': voiceprints,
      'file_chips': chips,
    };
  }

  // ============================================================
  // Close
  // ============================================================
  void dispose() {
    _db?.dispose();
    _db = null;
  }

  // ============================================================
  // Helpers
  // ============================================================
  Memory _rowToMemory(Row r) => Memory(
        id: r['id'] as String,
        userId: userId,
        content: r['content'] as String,
        metadata: jsonDecode(r['metadata_json'] as String),
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  /// Encode a List<double> as little-endian f32 bytes for sqlite-vec.
  Uint8List _encodeEmbedding(List<double>? emb) {
    if (emb == null) return Uint8List(0);
    final f32 = Float32List.fromList(emb);
    return f32.buffer.asUint8List();
  }

  List<double> _decodeEmbedding(Uint8List bytes) {
    final f32 = bytes.buffer.asFloat32List();
    return f32.toList();
  }

  String _uuid() {
    // Simple unique id. (uuid package is also a dep if you prefer.)
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '${userId.substring(0, 8)}-$now';
  }
}
