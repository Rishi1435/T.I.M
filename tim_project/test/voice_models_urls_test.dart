// Verifies every voice-model URL in the catalog is reachable.
// Run with: flutter test test/voice_models_urls_test.dart
// (Requires network; skip in offline CI with --exclude-tags=network.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_companion/data/services/voice_models_catalog.dart';

void main() {
  test('all voice model URLs respond', () async {
    final client = HttpClient();
    for (final spec in VoiceModelsCatalog.specs) {
      final req = await client.headUrl(Uri.parse(spec.url));
      req.followRedirects = true;
      final res = await req.close();
      expect(res.statusCode, lessThan(400),
          reason: '${spec.id} → ${spec.url} returned ${res.statusCode}');
      await res.drain<void>();
    }
    client.close();
  }, tags: ['network'], timeout: const Timeout(Duration(minutes: 2)));
}
