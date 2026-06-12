import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_ai_settings.dart';
import 'package:jarviscopilot_mobile/services/local_router.dart';
import 'package:jarviscopilot_mobile/services/local_tool_catalog.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';

class _FakeAi implements OnDeviceAiClient {
  _FakeAi({this.avail, this.decision, this.routeDelay, this.throwOnRoute = false});

  OnDeviceAvailability? avail;
  RoutingDecision? decision;
  Duration? routeDelay;
  bool throwOnRoute;

  @override
  Future<OnDeviceAvailability> availability() async =>
      avail ?? OnDeviceAvailability(available: true, engine: 'apple-fm');

  @override
  Future<RoutingDecision> route(LocalRequest req) async {
    if (routeDelay != null) await Future<void>.delayed(routeDelay!);
    if (throwOnRoute) throw StateError('boom');
    return decision ?? RoutingDecision.escalate('none');
  }

  @override
  Stream<String> generate(LocalRequest req) => const Stream.empty();
}

class _FakeCatalog implements ToolCatalog {
  _FakeCatalog(this.classes);
  final Map<String, ToolExecClass> classes;
  @override
  Future<String> buildPromptCatalog() async => '[]';
  @override
  ToolExecClass classOf(String name) =>
      classes[name] ?? ToolExecClass.serverOnly;
}

LocalAiSettings _settings({
  LocalAiTier tier = LocalAiTier.routerCommands,
  bool chat = true,
  bool voice = true,
  double conf = 0.55,
}) {
  return LocalAiSettings()
    ..tier = tier
    ..chatEnabled = chat
    ..voiceEnabled = voice
    ..confidenceFloor = conf;
}

void main() {
  group('LocalRouter gating', () {
    test('tier off escalates without calling the engine', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'answer', answer: 'hi', confidence: 1)),
        catalog: _FakeCatalog(const {}),
        settings: _settings(tier: LocalAiTier.off),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, 'tier-off');
    });

    test('surface disabled escalates', () async {
      final r = LocalRouter(
        ai: _FakeAi(),
        catalog: _FakeCatalog(const {}),
        settings: _settings(chat: false),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, 'chat-disabled');
    });

    test('empty input escalates', () async {
      final r = LocalRouter(
        ai: _FakeAi(),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      expect(await r.handle('   ', VoiceSurface.chat), isA<Escalate>());
    });

    test('unavailable engine escalates', () async {
      final r = LocalRouter(
        ai: _FakeAi(avail: OnDeviceAvailability.unavailable('appleIntelligenceOff')),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, contains('unavailable'));
    });
  });

  group('LocalRouter decisions', () {
    test('answer with high confidence → DirectAnswer', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'answer', answer: 'Hi there', confidence: 0.9)),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<DirectAnswer>());
      expect((res as DirectAnswer).text, 'Hi there');
    });

    test('answer with low confidence → Escalate', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'answer', answer: 'maybe', confidence: 0.2)),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, 'low-confidence');
    });

    test('empty inline answer still answers locally (caller generates)', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'answer', answer: '  ', confidence: 0.99)),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      final res = await r.handle('hi', VoiceSurface.chat);
      expect(res, isA<DirectAnswer>());
      expect((res as DirectAnswer).text, isEmpty);
    });

    test('device-local tool in baseline tier → ToolCall', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'tool', toolName: 'set_timer', toolArgs: {'minutes': 5}, confidence: 0.9)),
        catalog: _FakeCatalog(const {'set_timer': ToolExecClass.deviceLocal}),
        settings: _settings(tier: LocalAiTier.routerCommands),
      );
      final res = await r.handle('set a 5 minute timer', VoiceSurface.voice);
      expect(res, isA<ToolCall>());
      final tc = res as ToolCall;
      expect(tc.name, 'set_timer');
      expect(tc.args['minutes'], 5);
      expect(tc.execClass, ToolExecClass.deviceLocal);
    });

    test('server-only tool → Escalate', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'tool', toolName: 'web_search', confidence: 0.95)),
        catalog: _FakeCatalog(const {'web_search': ToolExecClass.serverOnly}),
        settings: _settings(),
      );
      expect((await r.handle('search the web', VoiceSurface.chat) as Escalate).reason, 'server-tool');
    });

    test('client-dispatchable tool needs full-local-first tier', () async {
      final dec = RoutingDecision(action: 'tool', toolName: 'chrome_open', confidence: 0.9);
      final catalog = _FakeCatalog(const {'chrome_open': ToolExecClass.clientDispatchable});

      final baseline = LocalRouter(ai: _FakeAi(decision: dec), catalog: catalog, settings: _settings(tier: LocalAiTier.routerCommands));
      expect((await baseline.handle('open chrome', VoiceSurface.chat) as Escalate).reason, 'client-tool-needs-full-tier');

      final full = LocalRouter(ai: _FakeAi(decision: dec), catalog: catalog, settings: _settings(tier: LocalAiTier.fullLocalFirst));
      expect(await full.handle('open chrome', VoiceSurface.chat), isA<ToolCall>());
    });

    test('outward/destructive device tool is flagged requiresConfirm', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'tool', toolName: 'send_message', toolArgs: {'to': 'mom'}, confidence: 0.9)),
        catalog: _FakeCatalog(const {'send_message': ToolExecClass.deviceLocal}),
        settings: _settings(), // confirmLocalActions defaults true
      );
      final res = await r.handle('text mom hi', VoiceSurface.voice);
      expect(res, isA<ToolCall>());
      expect((res as ToolCall).requiresConfirm, isTrue);
    });

    test('safe device tool is not flagged requiresConfirm', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'tool', toolName: 'set_timer', toolArgs: {'minutes': 5}, confidence: 0.9)),
        catalog: _FakeCatalog(const {'set_timer': ToolExecClass.deviceLocal}),
        settings: _settings(),
      );
      expect(((await r.handle('timer 5', VoiceSurface.voice)) as ToolCall).requiresConfirm, isFalse);
    });

    test('tool with empty name → Escalate', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'tool', toolName: '', confidence: 0.9)),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      expect((await r.handle('do', VoiceSurface.chat) as Escalate).reason, 'no-tool-name');
    });

    test('model says escalate → Escalate with reason', () async {
      final r = LocalRouter(
        ai: _FakeAi(decision: RoutingDecision(action: 'escalate', reason: 'needs-data')),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      expect((await r.handle('what is my balance', VoiceSurface.chat) as Escalate).reason, 'needs-data');
    });
  });

  group('LocalRouter resilience', () {
    test('hang-guard escalates only a wedged inference (not a normal slow one)', () async {
      final r = LocalRouter(
        ai: _FakeAi(
          decision: RoutingDecision(action: 'answer', answer: 'slow', confidence: 1),
          routeDelay: const Duration(milliseconds: 200),
        ),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
        hangGuardMs: 30, // tiny guard for the test; production is generous
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, 'hang-guard');
    });

    test('route throwing → Escalate', () async {
      final r = LocalRouter(
        ai: _FakeAi(throwOnRoute: true),
        catalog: _FakeCatalog(const {}),
        settings: _settings(),
      );
      final res = await r.handle('hello', VoiceSurface.chat);
      expect(res, isA<Escalate>());
      expect((res as Escalate).reason, startsWith('error:'));
    });
  });
}
