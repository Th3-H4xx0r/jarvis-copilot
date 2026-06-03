import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/app_lifecycle.dart';
import 'package:jarviscopilot_mobile/services/pending_actions.dart';
import 'package:jarviscopilot_mobile/skills/action_banner.dart';

void main() {
  group('shouldDeferToForeground', () {
    test('defers a foreground-required skill only when backgrounded', () {
      expect(
          shouldDeferToForeground(requiresForeground: true, isForeground: false),
          isTrue);
      expect(
          shouldDeferToForeground(requiresForeground: true, isForeground: true),
          isFalse);
    });
    test('never defers a non-foreground skill', () {
      expect(
          shouldDeferToForeground(requiresForeground: false, isForeground: false),
          isFalse);
    });
  });

  group('actionBannerTitle', () {
    test('open_app names the app', () {
      expect(actionBannerTitle('open_app', {'app': 'Robinhood'}), 'Open Robinhood');
    });
    test('open_url uses the host', () {
      expect(actionBannerTitle('open_url', {'url': 'https://www.google.com/x'}),
          'Open www.google.com');
    });
    test('phone_control brightness as percent', () {
      expect(actionBannerTitle('phone_control', {'action': 'brightness', 'value': 0.3}),
          'Set brightness 30%');
    });
    test('phone_control wifi off', () {
      expect(actionBannerTitle('phone_control', {'action': 'wifi', 'value': 0}),
          'Turn off Wi-Fi');
    });
    test('unknown skill falls back', () {
      expect(actionBannerTitle('mystery', {}), 'JARVIS action ready');
    });
    test('clamps a pathological title', () {
      expect(actionBannerTitle('open_app', {'app': 'Z' * 400}).length <= 100, isTrue);
    });
  });

  group('PendingActions', () {
    test('add then drainFresh returns and clears', () {
      final p = PendingActions.instance;
      p.drainFresh(); // clear any leftover
      p.add('open_app', {'app': 'X'});
      p.add('open_url', {'url': 'y://'});
      expect(p.length, 2);
      final out = p.drainFresh();
      expect(out.map((a) => a.skill), ['open_app', 'open_url']);
      expect(p.isEmpty, isTrue);
    });
    test('drops actions older than the TTL', () {
      final p = PendingActions.instance;
      p.drainFresh();
      final old = DateTime(2020, 1, 1);
      p.add('open_app', {'app': 'stale'}, at: old);
      p.add('open_app', {'app': 'fresh'});
      final out = p.drainFresh();
      expect(out.map((a) => a.args['app']), ['fresh']);
    });
  });
}
