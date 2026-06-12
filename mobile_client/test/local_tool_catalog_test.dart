import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_tool_catalog.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';
import 'package:jarviscopilot_mobile/skills/registry.dart';

SkillEntry _skill(String name) => SkillEntry(
      name: name,
      description: 'desc for $name',
      inputSchema: const {'type': 'object'},
      run: (args) async => {'ok': true},
    );

void main() {
  setUp(() {
    // A device-local skill (in the offline allowlist) and a client-dispatchable
    // one (a registered skill NOT in the offline allowlist).
    SkillRegistry.instance.register(_skill('set_timer'));
    SkillRegistry.instance.register(_skill('chrome_open'));
  });

  test('classOf tags device-local, client-dispatchable, and server-only', () {
    final cat = LocalToolCatalog()
      ..setServerToolsForTest([
        {'name': 'web_search', 'description': 'search the web'},
      ]);

    expect(cat.classOf('set_timer'), ToolExecClass.deviceLocal);
    expect(cat.classOf('chrome_open'), ToolExecClass.clientDispatchable);
    expect(cat.classOf('web_search'), ToolExecClass.serverOnly);
    // Unknown names default to serverOnly (safe → escalate).
    expect(cat.classOf('totally_unknown'), ToolExecClass.serverOnly);
  });

  test('buildPromptCatalog includes skills + server tools with execClass', () async {
    final cat = LocalToolCatalog()
      ..setServerToolsForTest([
        {'name': 'web_search', 'description': 'search the web'},
      ]);

    final json = jsonDecode(await cat.buildPromptCatalog()) as List;
    final byName = {for (final e in json) (e as Map)['name']: e};

    expect(byName.containsKey('set_timer'), isTrue);
    expect(byName.containsKey('chrome_open'), isTrue);
    expect(byName.containsKey('web_search'), isTrue);
    expect((byName['set_timer'] as Map)['execClass'], 'deviceLocal');
    expect((byName['web_search'] as Map)['execClass'], 'serverOnly');
    // Each entry carries name/desc/execClass.
    expect((byName['set_timer'] as Map).keys.toSet(),
        {'name', 'desc', 'execClass'});
  });
}
