import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/island/island_offline.dart';

void main() {
  final tl = <Map<String, dynamic>>[
    {'at': 100, 'data': {'phase': 'Boarding'}},
    {'at': 200, 'data': {'phase': 'In flight'}},
    {'at': 300, 'data': {'phase': 'Landed'}},
  ];

  group('currentKeyframeData', () {
    test('empty timeline → {}', () {
      expect(currentKeyframeData(const [], 250), isEmpty);
    });
    test('before the first keyframe → {}', () {
      expect(currentKeyframeData(tl, 50), isEmpty);
    });
    test('picks the latest keyframe with at ≤ now (inclusive)', () {
      expect(currentKeyframeData(tl, 250)['phase'], 'In flight');
      expect(currentKeyframeData(tl, 200)['phase'], 'In flight');
      expect(currentKeyframeData(tl, 999)['phase'], 'Landed');
    });
    test('unsorted timeline still resolves correctly', () {
      final u = <Map<String, dynamic>>[
        {'at': 300, 'data': {'p': 'c'}},
        {'at': 100, 'data': {'p': 'a'}},
        {'at': 200, 'data': {'p': 'b'}},
      ];
      expect(currentKeyframeData(u, 250)['p'], 'b');
    });
    test('malformed entries are skipped', () {
      final m = <Map<String, dynamic>>[
        {'at': 'nope', 'data': {}},
        {'at': 100, 'data': {'p': 'a'}},
      ];
      expect(currentKeyframeData(m, 150)['p'], 'a');
    });
  });

  group('scheduledItemsSignature', () {
    test('stable for equal lists, sensitive to change', () {
      final a = <Map<String, dynamic>>[{'at': 1, 'title': 'x', 'body': 'y'}];
      final b = <Map<String, dynamic>>[{'at': 1, 'title': 'x', 'body': 'y'}];
      final c = <Map<String, dynamic>>[{'at': 2, 'title': 'x', 'body': 'y'}];
      expect(scheduledItemsSignature(a), scheduledItemsSignature(b));
      expect(scheduledItemsSignature(a) == scheduledItemsSignature(c), isFalse);
    });
    test('order-independent (sorted internally)', () {
      final a = <Map<String, dynamic>>[
        {'at': 1, 'title': 'x'},
        {'at': 2, 'title': 'y'},
      ];
      final b = <Map<String, dynamic>>[
        {'at': 2, 'title': 'y'},
        {'at': 1, 'title': 'x'},
      ];
      expect(scheduledItemsSignature(a), scheduledItemsSignature(b));
    });
    test('a changed tap-action reschedules (action is part of the signature)', () {
      final base = <Map<String, dynamic>>[{'at': 1, 'title': 'x'}];
      final withA = <Map<String, dynamic>>[
        {'at': 1, 'title': 'x', 'action': {'skill': 'run_code'}},
      ];
      final withB = <Map<String, dynamic>>[
        {'at': 1, 'title': 'x', 'action': {'skill': 'set_alarm'}},
      ];
      expect(scheduledItemsSignature(base) == scheduledItemsSignature(withA), isFalse);
      expect(scheduledItemsSignature(withA) == scheduledItemsSignature(withB), isFalse);
    });
    test('control-byte separators avoid field/row collisions', () {
      // "1|x" style content must not let two different lists collide.
      final a = <Map<String, dynamic>>[{'at': 1, 'title': 'x', 'body': 'yz'}];
      final b = <Map<String, dynamic>>[{'at': 1, 'title': 'xy', 'body': 'z'}];
      expect(scheduledItemsSignature(a) == scheduledItemsSignature(b), isFalse);
    });
    test('empty list → empty signature', () {
      expect(scheduledItemsSignature(const []), '');
    });
  });
}
