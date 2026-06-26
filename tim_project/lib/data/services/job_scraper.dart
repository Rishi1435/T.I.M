// ============================================================
// lib/data/services/job_scraper.dart
// Phase 7 — Job Mentorship.
//
// Triggers an offline SearXNG instance to fetch live job listings,
// then runs cosine similarity between each listing's requirements
// and the user's encrypted local vault profile. Returns ranked
// matches with skill-gap warnings.
// ============================================================

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/utils/logger.dart';
import 'local_vault.dart';
import 'llm_engine.dart';

class JobListing {
  JobListing({
    required this.title,
    required this.company,
    required this.url,
    required this.snippet,
    required this.similarity,
    required this.skillGaps,
  });
  final String title;
  final String company;
  final String url;
  final String snippet;
  final double similarity; // 0..1 vs user profile
  final List<String> skillGaps;
}

class JobScraper {
  JobScraper(this._vault, this._llm)
      : _log = Logger('JobScraper');

  final LocalVault _vault;
  final LlmEngine _llm;
  final Logger _log;

  /// SearXNG endpoint (local instance). Override via constructor
  /// if you bundle it differently.
  static const String searxngUrl = 'http://localhost:8080';

  /// Search SearXNG for `query` and return up to [limit] raw listings.
  Future<List<Map<String, dynamic>>> _searchSearx(
    String query,
    int limit,
  ) async {
    final uri = Uri.parse('$searxngUrl/search'
        '?q=${Uri.encodeQueryComponent(query)}'
        '&format=json'
        '&categories=jobs'
        '&pageno=1');
    try {
      final resp = await http.get(uri, headers: {'Accept': 'application/json'});
      if (resp.statusCode != 200) {
        _log.warn('SearXNG returned ${resp.statusCode}');
        return [];
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = (body['results'] as List).cast<Map<String, dynamic>>();
      return results.take(limit).toList();
    } catch (e) {
      _log.warn('SearXNG unreachable ($e); returning empty.');
      return [];
    }
  }

  /// Top-level entry point: search → embed → cosine-match → rank.
  Future<List<JobListing>> findInternships({
    String query = 'software engineer intern Flutter AWS',
    int limit = 10,
  }) async {
    _log.info('Scraping internships: "$query"');
    final raw = await _searchSearx(query, limit);
    if (raw.isEmpty) return [];

    // Embed each listing and cosine-match against the user's vault.
    final memories = await _vault.listRecent(limit: 200);
    final profileText = memories.map((m) => m.content).join('\n');
    final profileEmb = await _llm.embed(profileText);

    final ranked = <JobListing>[];
    for (final r in raw) {
      final snippet = (r['content'] as String?) ?? '';
      final title = (r['title'] as String?) ?? 'Untitled';
      final url = (r['url'] as String?) ?? '';
      final company = _extractCompany(r);

      final emb = await _llm.embed('$title. $snippet');
      final sim = _cosine(emb, profileEmb);
      final gaps = _identifyGaps(snippet, profileText);

      ranked.add(
        JobListing(
          title: title,
          company: company,
          url: url,
          snippet: snippet,
          similarity: sim,
          skillGaps: gaps,
        ),
      );
    }
    ranked.sort((a, b) => b.similarity.compareTo(a.similarity));
    _log.info('Ranked ${ranked.length} listings; top sim='
              '${ranked.isEmpty ? 0 : ranked.first.similarity.toStringAsFixed(3)}');
    return ranked;
  }

  /// Heuristic skill-gap detector. Compares common tech keywords
  /// in the listing against the user's profile text.
  static List<String> _identifyGaps(String listing, String profile) {
    const skills = [
      'flutter', 'dart', 'aws', 'amplify', 'dynamodb',
      'python', 'java', 'kotlin', 'react', 'node',
      'postgres', 'mongodb', 'docker', 'kubernetes',
      'tensorflow', 'pytorch', 'whisper', 'llm',
    ];
    final l = listing.toLowerCase();
    final p = profile.toLowerCase();
    return skills
        .where((s) => l.contains(s) && !p.contains(s))
        .toList();
  }

  static String _extractCompany(Map<String, dynamic> r) {
    // SearXNG doesn't always set a company; use the hostname.
    final url = r['url'] as String? ?? '';
    try {
      final host = Uri.parse(url).host;
      return host.replaceAll('www.', '').split('.').first;
    } catch (_) {
      return 'Unknown';
    }
  }

  static double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (sqrt_(na) * sqrt_(nb));
  }

  static double sqrt_(double x) {
    if (x <= 0) return 0;
    var r = x / 2;
    for (var i = 0; i < 40; i++) {
      r = (r + x / r) / 2;
    }
    return r;
  }
}
