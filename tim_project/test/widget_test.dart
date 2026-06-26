import 'package:flutter_test/flutter_test.dart';
import 'package:tim_companion/core/config/app_config.dart';

void main() {
  test('AppConfig has expected defaults', () {
    expect(AppConfig.wsUrl, contains('ws://'));
    expect(AppConfig.modelRegistry.containsKey('llama3-8b'), isTrue);
  });
}
