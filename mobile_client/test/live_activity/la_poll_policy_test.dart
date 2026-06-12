import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/live_activity/la_poll_policy.dart';

void main() {
  group('laPollInterval', () {
    test('fast (5s) when voice is active', () {
      expect(
        laPollInterval(voiceActive: true, codingVisible: false, sessionTotal: 0),
        const Duration(seconds: 5),
      );
    });
    test('fast (5s) when the coding tab is visible', () {
      expect(
        laPollInterval(voiceActive: false, codingVisible: true, sessionTotal: 0),
        const Duration(seconds: 5),
      );
    });
    test('fast (5s) when there are live sessions', () {
      expect(
        laPollInterval(voiceActive: false, codingVisible: false, sessionTotal: 2),
        const Duration(seconds: 5),
      );
    });
    test('slow (60s) discovery when nothing is live and nobody is looking', () {
      expect(
        laPollInterval(voiceActive: false, codingVisible: false, sessionTotal: 0),
        const Duration(seconds: 60),
      );
    });
  });

  group('shouldFetchUsage', () {
    final base = DateTime(2026, 6, 12, 12, 0, 0);
    test('fetches when never fetched / stale (>=60s)', () {
      expect(shouldFetchUsage(now: base, lastUsageFetch: base.subtract(const Duration(seconds: 60))), isTrue);
      expect(shouldFetchUsage(now: base, lastUsageFetch: DateTime.fromMillisecondsSinceEpoch(0)), isTrue);
    });
    test('skips when fetched within 60s', () {
      expect(shouldFetchUsage(now: base, lastUsageFetch: base.subtract(const Duration(seconds: 30))), isFalse);
    });
  });
}
