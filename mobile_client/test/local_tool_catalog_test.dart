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
    // A real device-local skill (in the offline allowlist) and a real
    // registered skill that is NOT offline-capable (client-dispatchable).
    SkillRegistry.instance.register(_skill('vibrate'));
    SkillRegistry.instance.register(_skill('read_contacts'));
  });

  test('classOf tags device-local, client-dispatchable, and server-only', () {
    final cat = LocalToolCatalog()
      ..setServerToolsForTest([
        {'name': 'web_search', 'description': 'search the web'},
      ]);

    expect(cat.classOf('vibrate'), ToolExecClass.deviceLocal);
    expect(cat.classOf('read_contacts'), ToolExecClass.clientDispatchable);
    expect(cat.classOf('web_search'), ToolExecClass.serverOnly);
    // Unknown names default to serverOnly (safe → escalate).
    expect(cat.classOf('totally_unknown'), ToolExecClass.serverOnly);
  });

  test('buildPromptCatalog lists only executable device skills (no server tools)', () async {
    final cat = LocalToolCatalog()
      ..setServerToolsForTest([
        {'name': 'web_search', 'description': 'search the web'},
      ]);

    final json = jsonDecode(await cat.buildPromptCatalog()) as List;
    final names = json.map((e) => (e as Map)['name']).toSet();

    expect(names, contains('vibrate'));
    expect(names, contains('read_contacts'));
    // Server-only tools are deliberately NOT shown to the local model.
    expect(names, isNot(contains('web_search')));
    // Entries carry only name + desc (no execClass in the prompt).
    expect((json.first as Map).keys.toSet(), {'name', 'desc'});
  });
}
