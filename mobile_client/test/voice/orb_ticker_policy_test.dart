import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/voice/orb_ticker_policy.dart';

void main() {
  group('orbTickerEnabled', () {
    test('animates only when the owning tab is the active tab', () {
      // Voice-tab orb (owner = 1)
      expect(orbTickerEnabled(activeTab: 1, ownerTab: 1), isTrue);
      expect(orbTickerEnabled(activeTab: 0, ownerTab: 1), isFalse);
      expect(orbTickerEnabled(activeTab: 4, ownerTab: 1), isFalse);
      // Chat empty-state orb (owner = 0) animates on the Chat tab, not elsewhere
      expect(orbTickerEnabled(activeTab: 0, ownerTab: 0), isTrue);
      expect(orbTickerEnabled(activeTab: 1, ownerTab: 0), isFalse);
    });
    test('null owner always animates (not nav-gated)', () {
      expect(orbTickerEnabled(activeTab: 3, ownerTab: null), isTrue);
    });
  });
}
