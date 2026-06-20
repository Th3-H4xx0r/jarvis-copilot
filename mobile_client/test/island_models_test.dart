import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/island/island_models.dart';

void main() {
  test('IslandDesign.fromJson + jsonString round-trips', () {
    final raw = {
      'id': 'deploy',
      'name': 'Deploy status',
      'icon': 'shippingbox.fill',
      'version': 7,
      'presentations': {
        'expanded': {'type': 'text', 'value': 'hi'}
      }
    };
    final d = IslandDesign.fromJson(Map<String, dynamic>.from(raw));
    expect(d.id, 'deploy');
    expect(d.name, 'Deploy status');
    expect(d.version, 7);
    expect(jsonDecode(d.jsonString)['presentations']['expanded']['type'],
        'text');
  });

  test('IslandCatalogEntry defaults: enabled true, builtin false', () {
    final e = IslandCatalogEntry.fromJson({'id': 'x', 'priority': 5});
    expect(e.enabled, isTrue);
    expect(e.builtin, isFalse);
    expect(e.priority, 5);
    expect(e.conditions, isNull);
  });

  test('IslandCatalogEntry parses builtin + rules', () {
    final e = IslandCatalogEntry.fromJson({
      'id': 'voice',
      'builtin': true,
      'enabled': false,
      'priority': 100,
      'conditions': {'op': 'exists', 'a': {'\$': 'x'}},
      'schedule': {'from': '09:00', 'to': '17:00'}
    });
    expect(e.isVoice, isTrue);
    expect(e.builtin, isTrue);
    expect(e.enabled, isFalse);
    expect(e.conditions!['op'], 'exists');
    expect(e.schedule!['from'], '09:00');
  });

  test('IslandSelection parsing + defaults', () {
    expect(IslandSelection.fromJson(null).isAuto, isTrue);
    final s = IslandSelection.fromJson({'mode': 'pinned', 'pinnedId': 'deploy'});
    expect(s.isPinned, isTrue);
    expect(s.pinnedId, 'deploy');
    // unknown mode → auto
    expect(IslandSelection.fromJson({'mode': 'wat'}).isAuto, isTrue);
  });

  test('IslandCatalog.fromJson wires designs/catalog/selection/data', () {
    final cat = IslandCatalog.fromJson({
      'designs': [
        {
          'id': 'deploy',
          'name': 'Deploy',
          'version': 2,
          'presentations': {'expanded': {'type': 'divider'}}
        }
      ],
      'catalog': [
        {'id': 'voice', 'builtin': true, 'priority': 100},
        {'id': 'deploy', 'priority': 10}
      ],
      'selection': {'mode': 'pinned', 'pinnedId': 'deploy'},
      'data': {
        'deploy': {'pct': 62}
      }
    });
    expect(cat.designs.length, 1);
    expect(cat.designById('deploy')!.version, 2);
    expect(cat.entryById('voice')!.builtin, isTrue);
    expect(cat.selection.pinnedId, 'deploy');
    expect(cat.dataFor('deploy')['pct'], 62);
    expect(cat.dataFor('missing'), isEmpty);
  });

  test('IslandCatalog.empty is safe', () {
    expect(IslandCatalog.empty.designs, isEmpty);
    expect(IslandCatalog.empty.selection.isAuto, isTrue);
  });

  test('contentSig changes on a layout edit even without a version bump', () {
    IslandDesign d(String value) => IslandDesign.fromJson({
          'id': 'd',
          'version': 1, // SAME version
          'presentations': {
            'expanded': {'type': 'text', 'value': value}
          }
        });
    // Same version, different tree → different signature (so it re-caches live).
    expect(d('x').contentSig == d('y').contentSig, isFalse);
    // Identical content → same signature (no spurious re-cache/push).
    expect(d('x').contentSig == d('x').contentSig, isTrue);
  });
}
