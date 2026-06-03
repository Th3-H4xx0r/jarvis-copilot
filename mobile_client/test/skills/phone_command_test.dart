import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/skills/phone_command.dart';

void main() {
  group('phoneActionAwaitsResult', () {
    test('open_app / open_url are launch-type (do not await)', () {
      expect(phoneActionAwaitsResult('open_app'), isFalse);
      expect(phoneActionAwaitsResult('open_url'), isFalse);
    });
    test('get / set / media / scene / capabilities await a result', () {
      for (final a in ['get', 'set', 'media', 'scene', 'capabilities']) {
        expect(phoneActionAwaitsResult(a), isTrue, reason: a);
      }
    });
    test('unknown action defaults to awaiting (safer)', () {
      expect(phoneActionAwaitsResult('something_new'), isTrue);
    });
  });

  group('buildPhoneCommand', () {
    test('keeps action + provided params, drops nulls/empties/internal keys', () {
      final cmd = buildPhoneCommand({
        'action': 'open_app',
        'app': 'Spotify',
        'url': null,
        'value': '',
        'timeout_seconds': 30, // internal, must be dropped
      });
      expect(cmd, {'action': 'open_app', 'app': 'Spotify'});
    });
    test('preserves non-string values like numbers and bools', () {
      final cmd = buildPhoneCommand({
        'action': 'set',
        'setting': 'brightness',
        'value': 0.5,
      });
      expect(cmd, {'action': 'set', 'setting': 'brightness', 'value': 0.5});
    });
    test('throws when action missing', () {
      expect(() => buildPhoneCommand({'app': 'Spotify'}), throwsArgumentError);
    });
  });

  group('encodeQueryWithPercent20', () {
    test('encodes spaces as %20, never +', () {
      final qs = encodeQueryWithPercent20({'name': 'JarvisCopilot Runner'});
      expect(qs, 'name=JarvisCopilot%20Runner');
      expect(qs.contains('+'), isFalse);
    });
    test('percent-encodes JSON values and joins with &', () {
      final qs = encodeQueryWithPercent20({
        'name': 'JarvisCopilot Runner',
        'text': '{"action":"open_app","app":"Spotify"}',
      });
      expect(qs.startsWith('name=JarvisCopilot%20Runner&text='), isTrue);
      expect(qs.contains('%7B'), isTrue); // { encoded
      expect(qs.contains('%22'), isTrue); // " encoded
      expect(qs.contains('+'), isFalse);
    });
    test('round-trips through Uri.parse preserving %20', () {
      final qs = encodeQueryWithPercent20({'name': 'A B'});
      final uri = Uri.parse('shortcuts://x-callback-url/run-shortcut?$qs');
      expect(uri.toString().contains('A%20B'), isTrue);
      expect(uri.queryParameters['name'], 'A B'); // decodes back to a space
    });
  });

  group('nativeRedirectSkill', () {
    test('open_app / open_url redirect to the native skill', () {
      expect(nativeRedirectSkill({'action': 'open_app', 'app': 'Spotify'}),
          'open_app');
      expect(nativeRedirectSkill({'action': 'open_url', 'url': 'x'}), 'open_url');
    });
    test('get battery/location/clipboard redirect to native skills', () {
      expect(nativeRedirectSkill({'action': 'get', 'what': 'battery'}),
          'battery_level');
      expect(nativeRedirectSkill({'action': 'get', 'what': 'location'}),
          'get_location');
      expect(nativeRedirectSkill({'action': 'get', 'what': 'clipboard'}),
          'clipboard_read');
    });
    test('flashlight redirects to the native flashlight skill', () {
      expect(nativeRedirectSkill({'action': 'flashlight'}), contains('flashlight'));
    });
    test('Shortcut-only actions return null (no redirect)', () {
      expect(
          nativeRedirectSkill(
              {'action': 'set', 'setting': 'brightness', 'value': 0.5}),
          isNull);
      expect(nativeRedirectSkill({'action': 'scene', 'name': 'Movie Night'}),
          isNull);
      expect(nativeRedirectSkill({'action': 'get', 'what': 'now_playing'}), isNull);
      expect(nativeRedirectSkill({'action': 'custom_verb'}), isNull);
    });
  });

  group('parsePhoneOutput', () {
    test('parses a JSON object output', () {
      expect(parsePhoneOutput('{"ok":true,"result":"opened Spotify"}'),
          {'ok': true, 'result': 'opened Spotify'});
    });
    test('wraps non-JSON text as a raw result', () {
      expect(parsePhoneOutput('73%'), {'ok': true, 'result': '73%'});
    });
    test('empty output -> ok with empty result', () {
      expect(parsePhoneOutput(''), {'ok': true, 'result': ''});
      expect(parsePhoneOutput(null), {'ok': true, 'result': ''});
    });
    test('a JSON non-object (array/number) is treated as raw text', () {
      expect(parsePhoneOutput('[1,2]'), {'ok': true, 'result': '[1,2]'});
    });
  });
}
