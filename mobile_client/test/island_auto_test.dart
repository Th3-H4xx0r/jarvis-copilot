import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/island/island_auto.dart';
import 'package:jarviscopilot_mobile/island/island_models.dart';

IslandCatalogEntry _entry(String id,
        {bool builtin = false,
        bool enabled = true,
        int priority = 10,
        Map<String, dynamic>? conditions,
        Map<String, dynamic>? schedule}) =>
    IslandCatalogEntry(
      id: id,
      name: id,
      icon: '',
      version: 1,
      builtin: builtin,
      enabled: enabled,
      priority: priority,
      conditions: conditions,
      schedule: schedule,
    );

IslandDesign _design(String id) =>
    IslandDesign(id: id, name: id, icon: '', version: 1, raw: {'id': id});

IslandCatalog _cat({
  List<IslandCatalogEntry> extra = const [],
  List<IslandDesign> designs = const [],
  IslandSelection selection = IslandSelection.auto,
}) =>
    IslandCatalog(
      entries: [
        _entry('voice', builtin: true, priority: 100),
        _entry('coding', builtin: true, priority: 50),
        ...extra,
      ],
      designs: designs,
      selection: selection,
      data: const {},
    );

final _now = DateTime(2026, 6, 19, 14, 0); // a Friday 14:00

IslandActive _pick(IslandCatalog cat,
        {bool voice = false, bool coding = false, Map<String, dynamic>? sources}) =>
    selectActiveDesign(
      catalog: cat,
      voiceActive: voice,
      codingLive: coding,
      sources: sources ?? const {},
      now: _now,
    );

void main() {
  test('live voice turn always wins', () {
    final cat = _cat(
        selection: const IslandSelection(mode: 'pinned', pinnedId: 'coding'));
    expect(_pick(cat, voice: true, coding: true).kind, 'voice');
  });

  test('pinned custom design shows', () {
    final cat = _cat(
      extra: [_entry('deploy')],
      designs: [_design('deploy')],
      selection: const IslandSelection(mode: 'pinned', pinnedId: 'deploy'),
    );
    final a = _pick(cat);
    expect(a.kind, 'custom');
    expect(a.id, 'deploy');
  });

  test('pinned coding shows coding', () {
    final cat = _cat(
        selection: const IslandSelection(mode: 'pinned', pinnedId: 'coding'));
    expect(_pick(cat, coding: true).kind, 'coding');
  });

  test('pinned-to-missing-design falls through to auto', () {
    final cat = _cat(
        selection: const IslandSelection(mode: 'pinned', pinnedId: 'ghost'));
    expect(_pick(cat, coding: true).kind, 'coding');
    expect(_pick(cat).kind, 'none');
  });

  test('auto picks coding when sessions live and no custom', () {
    expect(_pick(_cat(), coding: true).kind, 'coding');
  });

  test('auto picks higher-priority custom over coding', () {
    final cat = _cat(
      extra: [_entry('deploy', priority: 60)],
      designs: [_design('deploy')],
    );
    final a = _pick(cat, coding: true);
    expect(a.kind, 'custom');
    expect(a.id, 'deploy');
  });

  test('lower-priority custom loses to coding', () {
    final cat = _cat(
      extra: [_entry('deploy', priority: 20)],
      designs: [_design('deploy')],
    );
    expect(_pick(cat, coding: true).kind, 'coding');
  });

  test('disabled custom is skipped', () {
    final cat = _cat(
      extra: [_entry('deploy', priority: 99, enabled: false)],
      designs: [_design('deploy')],
    );
    expect(_pick(cat, coding: true).kind, 'coding');
  });

  test('custom with unmet condition is skipped', () {
    final cat = _cat(
      extra: [
        _entry('deploy', priority: 99, conditions: {
          'op': 'gt',
          'a': {'src': 'battery.level'},
          'b': 20
        })
      ],
      designs: [_design('deploy')],
    );
    // no battery in sources → condition false → coding wins
    expect(_pick(cat, coding: true).kind, 'coding');
    // battery high → custom wins
    final a = _pick(cat, coding: true, sources: {'battery.level': 80});
    expect(a.id, 'deploy');
  });

  test('nothing live → none', () {
    expect(_pick(_cat()).kind, 'none');
  });

  test('schedule outside window excludes the design', () {
    final cat = _cat(
      extra: [
        _entry('night', priority: 99, schedule: {'from': '22:00', 'to': '23:00'})
      ],
      designs: [_design('night')],
    );
    // 14:00 is outside 22-23 → falls back to coding
    expect(_pick(cat, coding: true).kind, 'coding');
  });

  test('schedule inside window includes the design', () {
    final cat = _cat(
      extra: [
        _entry('work', priority: 99, schedule: {
          'days': [5],
          'from': '09:00',
          'to': '17:00'
        })
      ],
      designs: [_design('work')],
    );
    final a = _pick(cat, coding: true); // Friday(5) 14:00 → in window
    expect(a.id, 'work');
  });
}
