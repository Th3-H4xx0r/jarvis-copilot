import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/island/island_bindings.dart';
import 'package:jarviscopilot_mobile/island/island_models.dart';

void main() {
  group('evaluateCondition', () {
    test('null / empty is always true', () {
      expect(evaluateCondition(null, {}), isTrue);
      expect(evaluateCondition({}, {}), isTrue);
    });

    test('gt / lt with a source operand', () {
      final c = {
        'op': 'gt',
        'a': {'src': 'battery.level'},
        'b': 20
      };
      expect(evaluateCondition(c, {'battery.level': 50}), isTrue);
      expect(evaluateCondition(c, {'battery.level': 10}), isFalse);
    });

    test('missing operand fails safe (false)', () {
      final c = {
        'op': 'gt',
        'a': {'src': 'battery.level'},
        'b': 20
      };
      expect(evaluateCondition(c, {}), isFalse);
    });

    test('eq / ne numeric and string', () {
      expect(
          evaluateCondition({
            'op': 'eq',
            'a': {'\$': 'state'},
            'b': 'running'
          }, {
            'state': 'running'
          }),
          isTrue);
      expect(
          evaluateCondition({
            'op': 'ne',
            'a': {'\$': 'n'},
            'b': 3
          }, {
            'n': 4
          }),
          isTrue);
    });

    test('and / or / not', () {
      final and = {
        'op': 'and',
        'items': [
          {'op': 'exists', 'a': {'src': 'x'}},
          {'op': 'gt', 'a': {'src': 'x'}, 'b': 0},
        ]
      };
      expect(evaluateCondition(and, {'x': 5}), isTrue);
      expect(evaluateCondition(and, {'x': -1}), isFalse);

      final orC = {
        'op': 'or',
        'items': [
          {'op': 'eq', 'a': {'src': 'a'}, 'b': 1},
          {'op': 'eq', 'a': {'src': 'b'}, 'b': 1},
        ]
      };
      expect(evaluateCondition(orC, {'a': 0, 'b': 1}), isTrue);
      expect(evaluateCondition(orC, {'a': 0, 'b': 0}), isFalse);

      final notC = {
        'op': 'not',
        'item': {'op': 'exists', 'a': {'src': 'x'}}
      };
      expect(evaluateCondition(notC, {}), isTrue);
      expect(evaluateCondition(notC, {'x': 1}), isFalse);
    });

    test('between', () {
      final c = {
        'op': 'between',
        'a': {'src': 'p'},
        'lo': 10,
        'hi': 20
      };
      expect(evaluateCondition(c, {'p': 15}), isTrue);
      expect(evaluateCondition(c, {'p': 25}), isFalse);
    });

    test('unknown op is false', () {
      expect(evaluateCondition({'op': 'wat'}, {}), isFalse);
    });
  });

  group('source resolution', () {
    test('collectSourceKeys finds nested src refs', () {
      final tree = {
        'type': 'vstack',
        'children': [
          {'type': 'text', 'value': {'src': 'battery.level'}},
          {
            'type': 'list',
            'data': {'src': 'coding.fleet'},
            'row': {'type': 'dot', 'color': {'\$': 'state'}}
          }
        ]
      };
      expect(collectSourceKeys(tree),
          containsAll(<String>['battery.level', 'coding.fleet']));
    });

    test('resolveData overlays server data with known sources', () {
      const design = IslandDesign(
        id: 'd',
        name: 'd',
        icon: '',
        version: 1,
        raw: {
          'type': 'hstack',
          'children': [
            {'type': 'text', 'value': {'src': 'battery.level'}},
            {'type': 'text', 'value': {'\$': 'deploy'}},
          ]
        },
      );
      final out = resolveData(
        design,
        {'battery.level': 42, 'time.now': 999},
        {'deploy': 'ok'},
      );
      expect(out['deploy'], 'ok'); // from server data
      expect(out['battery.level'], 42); // from sources (referenced)
      expect(out.containsKey('time.now'), isFalse); // not referenced → omitted
    });
  });
}
