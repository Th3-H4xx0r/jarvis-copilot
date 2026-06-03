import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/skills/phone_command.dart';

void main() {
  group('buildPhoneCommand', () {
    test('keeps action + provided params, drops nulls/empties/internal keys', () {
      final cmd = buildPhoneCommand({
        'action': 'open_url',
        'url': 'spotify://',
        'value': null,
        'extra': '',
        'timeout_seconds': 30, // internal, must be dropped
      });
      expect(cmd, {'action': 'open_url', 'url': 'spotify://'});
    });
    test('preserves non-string values like numbers and bools', () {
      final cmd = buildPhoneCommand({'action': 'brightness', 'value': 0.5});
      expect(cmd, {'action': 'brightness', 'value': 0.5});
    });
    test('throws when action missing', () {
      expect(() => buildPhoneCommand({'value': 0.5}), throwsArgumentError);
    });
  });

  group('rawValueForVerb', () {
    test('brightness/volume pass a 0–1 decimal through', () {
      expect(rawValueForVerb('brightness', {'value': 0.3}), '0.3');
      expect(rawValueForVerb('volume', {'value': '0.55'}), '0.55');
    });
    test('brightness accepts a percentage and converts to 0–1', () {
      expect(rawValueForVerb('brightness', {'value': 30}), '0.3');
      expect(rawValueForVerb('brightness', {'value': '80%'}), '0.8');
    });
    test('brightness clamps out-of-range values', () {
      expect(rawValueForVerb('brightness', {'value': 150}), '1.0');
      expect(rawValueForVerb('brightness', {'value': -2}), '0.0');
    });
    test('wifi/bluetooth/focus normalize truthy/falsy words to 1/0', () {
      expect(rawValueForVerb('wifi', {'value': 'on'}), '1');
      expect(rawValueForVerb('wifi', {'value': true}), '1');
      expect(rawValueForVerb('bluetooth', {'value': 'off'}), '0');
      expect(rawValueForVerb('focus', {'value': 0}), '0');
    });
    test('open_url passes the url through', () {
      expect(rawValueForVerb('open_url', {'url': 'https://x.com'}),
          'https://x.com');
    });
  });

  group('phoneShortcutFor', () {
    test('maps each supported verb to its JC <Verb> Shortcut + raw input', () {
      expect(phoneShortcutFor({'action': 'brightness', 'value': 0.3}),
          (name: 'JC Brightness', input: '0.3'));
      expect(phoneShortcutFor({'action': 'volume', 'value': 0.5}),
          (name: 'JC Volume', input: '0.5'));
      expect(phoneShortcutFor({'action': 'wifi', 'value': 0}),
          (name: 'JC WiFi', input: '0'));
      expect(phoneShortcutFor({'action': 'bluetooth', 'value': 'on'}),
          (name: 'JC Bluetooth', input: '1'));
      expect(phoneShortcutFor({'action': 'focus', 'value': 1}),
          (name: 'JC Focus', input: '1'));
      expect(phoneShortcutFor({'action': 'open_url', 'url': 'x://'}),
          (name: 'JC Open URL', input: 'x://'));
    });
    test('returns null for a verb with no Shortcut', () {
      expect(phoneShortcutFor({'action': 'flashlight'}), isNull);
      expect(phoneShortcutFor({'action': 'made_up'}), isNull);
    });
  });

  group('encodeQueryWithPercent20', () {
    test('encodes spaces as %20, never +', () {
      final qs = encodeQueryWithPercent20({'name': 'JC Brightness'});
      expect(qs, 'name=JC%20Brightness');
      expect(qs.contains('+'), isFalse);
    });
    test('percent-encodes values and joins with &', () {
      final qs = encodeQueryWithPercent20({
        'name': 'JC Open URL',
        'text': 'spotify://playlist',
      });
      expect(qs.startsWith('name=JC%20Open%20URL&text='), isTrue);
      expect(qs.contains('%3A'), isTrue); // : encoded
      expect(qs.contains('+'), isFalse);
    });
    test('round-trips through Uri.parse preserving %20', () {
      final qs = encodeQueryWithPercent20({'name': 'A B'});
      final uri = Uri.parse('shortcuts://x-callback-url/run-shortcut?$qs');
      expect(uri.toString().contains('A%20B'), isTrue);
      expect(uri.queryParameters['name'], 'A B');
    });
  });

  group('nativeRedirectSkill', () {
    test('open_app / alarm / flashlight redirect to native skills', () {
      expect(nativeRedirectSkill({'action': 'open_app', 'app': 'Spotify'}),
          'open_app');
      expect(nativeRedirectSkill({'action': 'alarm', 'time': '7:00 AM'}),
          'set_alarm');
      expect(nativeRedirectSkill({'action': 'flashlight'}),
          contains('flashlight'));
    });
    test('get battery/location/clipboard redirect to native skills', () {
      expect(nativeRedirectSkill({'action': 'get', 'what': 'battery'}),
          'battery_level');
      expect(nativeRedirectSkill({'action': 'get', 'what': 'location'}),
          'get_location');
      expect(nativeRedirectSkill({'action': 'get', 'what': 'clipboard'}),
          'clipboard_read');
    });
    test('Shortcut verbs return null (no redirect)', () {
      expect(nativeRedirectSkill({'action': 'brightness', 'value': 0.5}), isNull);
      expect(nativeRedirectSkill({'action': 'wifi', 'value': 0}), isNull);
      expect(nativeRedirectSkill({'action': 'open_url', 'url': 'x://'}), isNull);
    });
  });

  group('parsePhoneOutput', () {
    test('parses a JSON object output', () {
      expect(parsePhoneOutput('{"ok":true,"result":"done"}'),
          {'ok': true, 'result': 'done'});
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
