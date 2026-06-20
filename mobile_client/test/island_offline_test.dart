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

  group('notificationsSignature', () {
    test('stable for equal lists, sensitive to change', () {
      final a = <Map<String, dynamic>>[{'at': 1, 'title': 'x', 'body': 'y'}];
      final b = <Map<String, dynamic>>[{'at': 1, 'title': 'x', 'body': 'y'}];
      final c = <Map<String, dynamic>>[{'at': 2, 'title': 'x', 'body': 'y'}];
      expect(notificationsSignature(a), notificationsSignature(b));
      expect(notificationsSignature(a) == notificationsSignature(c), isFalse);
    });
    test('empty list → empty signature', () {
      expect(notificationsSignature(const []), '');
    });
  });
}
