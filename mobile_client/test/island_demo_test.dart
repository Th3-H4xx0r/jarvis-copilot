import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/island/island_demo.dart';
import 'package:jarviscopilot_mobile/island/island_models.dart';

void main() {
  test('bundled demo is a regions design that parses', () {
    expect(islandDemoDesign['id'], 'demo');
    final pres = islandDemoDesign['presentations'] as Map;
    expect((pres['expanded'] as Map)['type'], 'regions');
    final d = IslandDesign.fromJson(Map<String, dynamic>.from(islandDemoDesign));
    expect(d.name, 'UI Example (max size)');
    expect(d.version, 6);
  });

  test('bundled demo progress bar carries a tip indicator', () {
    final expanded =
        (islandDemoDesign['presentations'] as Map)['expanded'] as Map;
    final bottom = (expanded['bottom'] as Map)['children'] as List;
    final progress =
        bottom.firstWhere((n) => n is Map && n['type'] == 'progress') as Map;
    expect(progress['tip'], isA<Map>());
    expect((progress['tip'] as Map)['symbol'], 'airplane');
  });

  test('injectBundledDemo replaces the server demo + preserves user overrides', () {
    final raw = <String, dynamic>{
      'designs': [
        {'id': 'demo', 'version': 1, 'presentations': {}},
        {'id': 'deploy', 'version': 1},
      ],
      'catalog': [
        {'id': 'demo', 'builtin': true, 'enabled': true, 'priority': 9},
        {'id': 'deploy'},
      ],
      'selection': {'mode': 'auto'},
    };
    injectBundledDemo(raw);

    final demos =
        (raw['designs'] as List).where((d) => d['id'] == 'demo').toList();
    expect(demos.length, 1); // server copy replaced, not duplicated
    expect((demos.first as Map)['version'], 6); // bundled version wins
    expect(((demos.first as Map)['presentations'] as Map)['expanded']['type'],
        'regions');
    // deploy untouched
    expect((raw['designs'] as List).any((d) => d['id'] == 'deploy'), isTrue);

    final cat = (raw['catalog'] as List).where((c) => c['id'] == 'demo').toList();
    expect(cat.length, 1);
    expect((cat.first as Map)['enabled'], true); // user override preserved
    expect((cat.first as Map)['priority'], 9);
  });

  test('injectBundledDemo handles a missing/empty payload', () {
    final raw = <String, dynamic>{};
    injectBundledDemo(raw);
    expect((raw['designs'] as List).any((d) => d['id'] == 'demo'), isTrue);
    expect((raw['catalog'] as List).any((c) => c['id'] == 'demo'), isTrue);
  });
}
