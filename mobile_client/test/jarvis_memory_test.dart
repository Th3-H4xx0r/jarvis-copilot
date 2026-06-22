import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/jarvis_memory.dart';

void main() {
  group('parseNamespaces', () {
    test('real /stats shape {namespaces:[{namespace,count}]}', () {
      final out = JarvisMemoryApi.parseNamespaces({
        'available': true,
        'count': 7,
        'namespaces': [
          {'namespace': 'global', 'count': 5},
          {'namespace': 'work', 'count': 2},
        ],
      });
      expect(out.length, 2);
      expect(out[0]['namespace'], 'global');
      expect(out[0]['count'], 5);
      expect(out[1]['namespace'], 'work');
      expect(out[1]['count'], 2);
    });

    test('bare list of namespace maps is accepted', () {
      final out = JarvisMemoryApi.parseNamespaces([
        {'namespace': 'a', 'count': 1},
        {'namespace': 'b', 'count': 3},
      ]);
      expect(out.map((m) => m['namespace']).toList(), ['a', 'b']);
      expect(out.map((m) => m['count']).toList(), [1, 3]);
    });

    test('count coerces numeric strings and defaults missing to 0', () {
      final out = JarvisMemoryApi.parseNamespaces({
        'namespaces': [
          {'namespace': 'x', 'count': '9'},
          {'namespace': 'y'}, // no count
        ],
      });
      expect(out[0]['count'], 9);
      expect(out[1]['count'], 0);
    });

    test('tolerates "name" as an alias for "namespace"', () {
      final out = JarvisMemoryApi.parseNamespaces({
        'namespaces': [
          {'name': 'aliased', 'count': 4},
        ],
      });
      expect(out.single['namespace'], 'aliased');
      expect(out.single['count'], 4);
    });

    test('empty / missing / null / wrong-type → const []', () {
      expect(JarvisMemoryApi.parseNamespaces({'namespaces': []}), isEmpty);
      expect(JarvisMemoryApi.parseNamespaces(<String, dynamic>{}), isEmpty);
      expect(JarvisMemoryApi.parseNamespaces(null), isEmpty);
      expect(JarvisMemoryApi.parseNamespaces('nope'), isEmpty);
      expect(JarvisMemoryApi.parseNamespaces({'namespaces': 42}), isEmpty);
    });

    test('skips entries with no usable name and non-map items', () {
      final out = JarvisMemoryApi.parseNamespaces({
        'namespaces': [
          {'namespace': '', 'count': 1}, // empty name → skip
          'garbage', // non-map → skip
          {'count': 2}, // no name key → skip
          {'namespace': 'keep', 'count': 8},
        ],
      });
      expect(out.length, 1);
      expect(out.single['namespace'], 'keep');
    });
  });

  group('parseEntries', () {
    test('real /search shape uses {entries:[...]} (NOT results)', () {
      final out = JarvisMemoryApi.parseEntries({
        'available': true,
        'namespace': 'global',
        'entries': [
          {'id': 'c1', 'body': 'hello', 'score': 0.9},
          {'id': 'c2', 'body': 'world', 'score': 0.4},
        ],
      });
      expect(out.length, 2);
      expect(out[0]['id'], 'c1');
      expect(out[0]['body'], 'hello');
    });

    test('tolerates {results:[...]} and a bare list', () {
      expect(
        JarvisMemoryApi.parseEntries({
          'results': [
            {'id': 'r1', 'body': 'x'}
          ],
        }).single['id'],
        'r1',
      );
      expect(
        JarvisMemoryApi.parseEntries([
          {'id': 'b1', 'body': 'y'}
        ]).single['id'],
        'b1',
      );
    });

    test('unavailable / empty / wrong-type → const []', () {
      expect(
        JarvisMemoryApi.parseEntries(
            {'available': false, 'error': 'no store', 'entries': []}),
        isEmpty,
      );
      expect(JarvisMemoryApi.parseEntries(null), isEmpty);
      expect(JarvisMemoryApi.parseEntries('nope'), isEmpty);
    });
  });

  group('asInt', () {
    test('int / num / numeric-string / null / junk', () {
      expect(JarvisMemoryApi.asInt(3), 3);
      expect(JarvisMemoryApi.asInt(3.9), 3);
      expect(JarvisMemoryApi.asInt(' 42 '), 42);
      expect(JarvisMemoryApi.asInt(null), 0);
      expect(JarvisMemoryApi.asInt('abc'), 0);
      expect(JarvisMemoryApi.asInt(<int>[]), 0);
    });
  });
}
