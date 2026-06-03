import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/voice/device_icon.dart';

void main() {
  group('deviceIconKind — real /api/devices records', () {
    test('browser session on a MacBook → laptop (by name)', () {
      expect(
        deviceIconKind({
          'kind': 'browser',
          'name': "Pranav's Macbook WebUI Remote",
          'user_agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X) Chrome/124',
        }),
        'laptop',
      );
    });
    test('native desktop agent on a MacBook → laptop', () {
      expect(deviceIconKind({'kind': 'desktop', 'name': 'Pranavs-MacBook-Pro.local'}),
          'laptop');
    });
    test('mobile-ios → phone', () {
      expect(deviceIconKind({'kind': 'mobile-ios', 'name': 'iPhone'}), 'phone');
    });
    test('mobile-android → phone', () {
      expect(deviceIconKind({'kind': 'mobile-android', 'name': 'Pixel 9'}), 'phone');
    });
  });

  group('deviceIconKind — derivation from user_agent', () {
    test('browser on Windows → desktop', () {
      expect(
        deviceIconKind({
          'kind': 'browser',
          'name': 'Chrome',
          'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64) Chrome/124',
        }),
        'desktop',
      );
    });
    test('generic browser with no hints → web (globe)', () {
      expect(deviceIconKind({'kind': 'browser', 'name': 'device', 'user_agent': ''}),
          'web');
    });
    test('iMac (desktop kind) → desktop, not laptop', () {
      expect(deviceIconKind({'kind': 'desktop', 'name': 'iMac'}), 'desktop');
    });
    test('macintosh UA with no macbook → laptop', () {
      expect(
        deviceIconKind({'kind': 'browser', 'name': 'Safari', 'user_agent': 'Macintosh'}),
        'laptop',
      );
    });
  });

  group('deviceIconKind — fallbacks', () {
    test('watch in the name → watch', () {
      expect(deviceIconKind({'name': 'My Apple Watch'}), 'watch');
    });
    test('iPad → tablet', () {
      expect(deviceIconKind({'kind': 'mobile-ios', 'name': 'iPad Pro'}), 'tablet');
    });
    test('unknown record → desktop default', () {
      expect(deviceIconKind({'name': '', 'user_agent': ''}), 'desktop');
    });
  });
}
