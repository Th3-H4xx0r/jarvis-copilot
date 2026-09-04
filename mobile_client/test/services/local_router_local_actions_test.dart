import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_ai_settings.dart';
import 'package:jarviscopilot_mobile/services/local_router.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';
import 'package:jarviscopilot_mobile/skills/registry.dart';

/// The router now consults the allow-listed device-action grammar
/// ([LocalExecutor]) before the older matcher, so chat gets the same Lane 0
/// actions voice does (plan 4.3).
///
/// Lives in its own file because [SkillRegistry] is process-global: registering
/// fake skills here must not change what the other router tests see.
class _FakeAi implements OnDeviceAiClient {
  @override
  Future<OnDeviceAvailability> availability() async =>
      OnDeviceAvailability(available: true, engine: 'apple-fm');

  @override
  Future<RoutingDecision> route(LocalRequest req) async =>
      RoutingDecision.escalate('unused');

  @override
  Stream<String> generate(LocalRequest req) => const Stream.empty();
}

LocalAiSettings _settings() => LocalAiSettings()
  ..tier = LocalAiTier.routerCommands
  ..chatEnabled = true
  ..voiceEnabled = true;

void main() {
  setUpAll(() {
    for (final name in ['set_alarm', 'clipboard_read', 'vibrate']) {
      SkillRegistry.instance.register(SkillEntry(
        name: name,
        description: name,
        inputSchema: const {'type': 'object'},
        run: (_) async => null,
      ));
    }
  });

  test('an allow-listed device action becomes a device-local ToolCall',
      () async {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());
    final res = await r.handle('set a timer for 10 minutes', VoiceSurface.chat);
    expect(res, isA<ToolCall>());
    final call = res as ToolCall;
    expect(call.name, 'set_alarm');
    expect(call.args['in_minutes'], 10);
    expect(call.execClass, ToolExecClass.deviceLocal);
    expect(call.confirmation, isNotEmpty);
  });

  test('a skill this device does not have is never run locally', () async {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());
    // take_photo is deliberately not registered above.
    expect(await r.handle('take a photo', VoiceSurface.chat), isNot(isA<ToolCall>()));
  });

  test('a guarded utterance escalates instead of running', () async {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());
    expect(
        await r.handle('set a timer for 10 minutes on my Mac', VoiceSurface.chat),
        isA<Escalate>());
  });

  test('the older matcher still handles what the executor skips', () async {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());
    // Texting is on the executor's escalate list, but LocalCommandMatcher has
    // its own (server-confirmed) path — unchanged by this integration.
    final res = await r.handle('vibrate the phone', VoiceSurface.chat);
    expect(res, isA<ToolCall>());
    expect((res as ToolCall).name, 'vibrate');
  });
}
