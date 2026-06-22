import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/workspaces.dart';

void main() {
  group('parseWorkspaceList', () {
    test('object entries → path + name preserved, last carried through', () {
      final out = parseWorkspaceList({
        'workspaces': [
          {'path': '/Users/me/code/alpha', 'name': 'Alpha'},
          {'path': '/Users/me/code/beta', 'name': 'Beta'},
        ],
        'last': '/Users/me/code/beta',
      });
      expect(out.workspaces, hasLength(2));
      expect(out.workspaces[0].path, '/Users/me/code/alpha');
      expect(out.workspaces[0].name, 'Alpha');
      expect(out.workspaces[1].name, 'Beta');
      expect(out.last, '/Users/me/code/beta');
    });

    test('order is preserved', () {
      final out = parseWorkspaceList({
        'workspaces': [
          {'path': '/a', 'name': 'A'},
          {'path': '/b', 'name': 'B'},
          {'path': '/c', 'name': 'C'},
        ],
        'last': '',
      });
      expect(out.workspaces.map((w) => w.path).toList(), ['/a', '/b', '/c']);
    });

    test('bare-string entries derive a name from the last path segment', () {
      final out = parseWorkspaceList({
        'workspaces': ['/Users/me/code/gamma', '/srv/'],
        'last': '/Users/me/code/gamma',
      });
      expect(out.workspaces, hasLength(2));
      expect(out.workspaces[0].path, '/Users/me/code/gamma');
      expect(out.workspaces[0].name, 'gamma');
      // Trailing slash is trimmed before taking the basename.
      expect(out.workspaces[1].name, 'srv');
    });

    test('entry missing a name falls back to the basename', () {
      final out = parseWorkspaceList({
        'workspaces': [
          {'path': '/Users/me/code/delta'},
        ],
        'last': '',
      });
      expect(out.workspaces.single.name, 'delta');
    });

    test('entries with empty paths are dropped', () {
      final out = parseWorkspaceList({
        'workspaces': [
          {'path': '', 'name': 'Ghost'},
          {'path': '/real', 'name': 'Real'},
        ],
        'last': '',
      });
      expect(out.workspaces, hasLength(1));
      expect(out.workspaces.single.path, '/real');
    });

    test('empty map → empty list, empty last', () {
      final out = parseWorkspaceList(<String, dynamic>{});
      expect(out.workspaces, isEmpty);
      expect(out.last, '');
    });

    test('missing workspaces key → empty list', () {
      final out = parseWorkspaceList({'last': '/somewhere'});
      expect(out.workspaces, isEmpty);
      expect(out.last, '/somewhere');
    });

    test('null input → empty list, empty last', () {
      final out = parseWorkspaceList(null);
      expect(out.workspaces, isEmpty);
      expect(out.last, '');
    });

    test('non-map input (e.g. a bare list) → empty list, empty last', () {
      final out = parseWorkspaceList([1, 2, 3]);
      expect(out.workspaces, isEmpty);
      expect(out.last, '');
    });

    test('non-list workspaces value → empty list', () {
      final out = parseWorkspaceList({'workspaces': 'oops', 'last': ''});
      expect(out.workspaces, isEmpty);
    });

    test('missing last → empty string (not null)', () {
      final out = parseWorkspaceList({
        'workspaces': [
          {'path': '/x', 'name': 'X'},
        ],
      });
      expect(out.last, '');
    });
  });
}
