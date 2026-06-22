import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/code_memory.dart';
import 'package:jarviscopilot_mobile/pages/more/code_memory_page.dart';

void main() {
  group('parseProjects', () {
    test('map keyed by slug → list carrying each slug', () {
      final raw = {
        'jarvis-copilot': {
          'name': 'JarvisCopilot',
          'knowledge_count': 12,
          'sessions_count': 3,
          'last_seen': '2026-06-21T10:00:00Z',
        },
        'other-repo': {
          'name': 'Other',
          'knowledge_count': 0,
          'sessions_count': 1,
        },
      };
      final out = parseProjects(raw);
      expect(out.length, 2);

      final jc = out.firstWhere((p) => p['slug'] == 'jarvis-copilot');
      expect(jc['name'], 'JarvisCopilot');
      expect(jc['knowledge_count'], 12);
      expect(jc['sessions_count'], 3);

      final other = out.firstWhere((p) => p['slug'] == 'other-repo');
      expect(other['name'], 'Other');
      expect(other['slug'], 'other-repo');
    });

    test('the map KEY wins as slug even if an inner slug field differs', () {
      final raw = {
        'real-slug': {'name': 'X', 'slug': 'stale'},
      };
      final out = parseProjects(raw);
      expect(out.single['slug'], 'real-slug');
    });

    test('bare list passes through (each item already has slug)', () {
      final raw = [
        {'slug': 'a', 'name': 'A'},
        {'slug': 'b', 'name': 'B'},
      ];
      final out = parseProjects(raw);
      expect(out.length, 2);
      expect(out[0]['slug'], 'a');
      expect(out[1]['name'], 'B');
    });

    test('list drops non-map items', () {
      final out = parseProjects([
        {'slug': 'a'},
        'garbage',
        42,
      ]);
      expect(out.length, 1);
      expect(out.single['slug'], 'a');
    });

    test('empty map → empty list', () {
      expect(parseProjects(<String, dynamic>{}), isEmpty);
    });

    test('null / non-collection → empty list', () {
      expect(parseProjects(null), isEmpty);
      expect(parseProjects('nope'), isEmpty);
      expect(parseProjects(7), isEmpty);
    });
  });

  group('relativeTime', () {
    String relFromSecondsAgo(int secondsAgo) {
      final dt =
          DateTime.now().toUtc().subtract(Duration(seconds: secondsAgo));
      return relativeTime(dt.toIso8601String());
    }

    test('null / empty / unparseable → empty string', () {
      expect(relativeTime(null), '');
      expect(relativeTime(''), '');
      expect(relativeTime('   '), '');
      expect(relativeTime('not-a-date'), '');
    });

    test('under a minute → just now', () {
      expect(relFromSecondsAgo(5), 'just now');
      expect(relFromSecondsAgo(59), 'just now');
    });

    test('minutes / hours / days ago', () {
      expect(relFromSecondsAgo(60 * 5), '5m ago');
      expect(relFromSecondsAgo(3600 * 2), '2h ago');
      expect(relFromSecondsAgo(86400 * 3), '3d ago');
    });

    test('older than a week → absolute YYYY-MM-DD date', () {
      // A fixed far-past date is always > 1 week old.
      final out = relativeTime('2020-01-15T08:30:00Z');
      // Local-tz date; assert the format/year rather than an exact day.
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(out), isTrue);
      expect(out.startsWith('2020-01-1'), isTrue);
    });

    test('accepts epoch seconds and milliseconds', () {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(relativeTime(nowSec - 120), '2m ago'); // seconds
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      expect(relativeTime(nowMs - 120 * 1000), '2m ago'); // millis
    });

    test('numeric STRING is treated as epoch', () {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(relativeTime('${nowSec - 7200}'), '2h ago');
    });

    test('future timestamp (clock skew) reads as just now', () {
      final future = DateTime.now().toUtc().add(const Duration(minutes: 5));
      expect(relativeTime(future.toIso8601String()), 'just now');
    });
  });
}
