import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/profiles.dart';

void main() {
  group('parseProfiles', () {
    test('parses the {profiles: [...], active: ...} shape', () {
      final data = {
        'profiles': [
          {'name': 'default', 'path': '/home/.jc', 'model': 'gpt', 'provider': 'openai'},
          {'name': 'coder', 'path': '/home/.jc/profiles/coder'},
        ],
        'active': 'coder',
      };
      final out = parseProfiles(data);
      expect(out, hasLength(2));
      expect(out[0]['name'], 'default');
      expect(out[1]['name'], 'coder');
      // Entries are real String-keyed maps, not the original Map type.
      expect(out.first, isA<Map<String, dynamic>>());
    });

    test('tolerates a bare list (no wrapping map)', () {
      final out = parseProfiles([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      expect(out.map((p) => p['name']), ['a', 'b']);
    });

    test('drops non-map entries', () {
      final out = parseProfiles({
        'profiles': [
          {'name': 'ok'},
          'garbage',
          42,
          null,
        ],
      });
      expect(out, hasLength(1));
      expect(out.single['name'], 'ok');
    });

    test('empty / malformed inputs yield an empty list', () {
      expect(parseProfiles(<String, dynamic>{}), isEmpty);
      expect(parseProfiles(null), isEmpty);
      expect(parseProfiles({'profiles': null}), isEmpty);
      expect(parseProfiles({'profiles': 'nope'}), isEmpty);
      expect(parseProfiles('totally wrong'), isEmpty);
    });
  });

  group('activeName', () {
    test('reads the active key from the list response', () {
      expect(activeName({'profiles': [], 'active': 'coder'}), 'coder');
    });

    test('reads the name key from the active-profile response', () {
      expect(activeName({'name': 'default', 'path': '/x'}), 'default');
    });

    test('switch response active key confirms the new profile', () {
      final switchResp = {
        'profiles': [
          {'name': 'coder'},
        ],
        'active': 'coder',
        'default_model': 'gpt',
      };
      expect(activeName(switchResp), 'coder');
    });

    test('missing / malformed inputs yield empty string', () {
      expect(activeName(<String, dynamic>{}), '');
      expect(activeName(null), '');
      expect(activeName('nope'), '');
      expect(activeName({'active': null}), '');
    });
  });
}
