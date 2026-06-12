import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_ai_settings.dart';
import 'package:jarviscopilot_mobile/services/local_router.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';

class _FakeAi implements OnDeviceAiClient {
  _FakeAi({this.avail});
  OnDeviceAvailability? avail;

  @override
  Future<OnDeviceAvailability> availability() async =>
      avail ?? OnDeviceAvailability(available: true, engine: 'apple-fm');

  @override
  Future<RoutingDecision> route(LocalRequest req) async =>
      RoutingDecision.escalate('unused');

  @override
  Stream<String> generate(LocalRequest req) => const Stream.empty();
}

LocalAiSettings _settings({
  LocalAiTier tier = LocalAiTier.routerCommands,
  bool chat = true,
  bool voice = true,
}) {
  return LocalAiSettings()
    ..tier = tier
    ..chatEnabled = chat
    ..voiceEnabled = voice;
}

void main() {
  group('LocalRouter gating', () {
    test('tier off escalates', () async {
      final r = LocalRouter(ai: _FakeAi(), settings: _settings(tier: LocalAiTier.off));
      expect((await r.handle('hello', VoiceSurface.chat) as Escalate).reason, 'tier-off');
    });

    test('surface disabled escalates', () async {
      final r = LocalRouter(ai: _FakeAi(), settings: _settings(chat: false));
      expect((await r.handle('hello', VoiceSurface.chat) as Escalate).reason, 'chat-disabled');
    });

    test('empty input escalates', () async {
      final r = LocalRouter(ai: _FakeAi(), settings: _settings());
      expect(await r.handle('   ', VoiceSurface.chat), isA<Escalate>());
    });

    test('unavailable engine escalates', () async {
      final r = LocalRouter(
        ai: _FakeAi(avail: OnDeviceAvailability.unavailable('off')),
        settings: _settings(),
      );
      expect((await r.handle('hello', VoiceSurface.chat) as Escalate).reason, contains('unavailable'));
    });
  });

  group('LocalRouter pre-gate (server requests escalate)', () {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());

    for (final cmd in [
      "what's the weather",
      'give me the morning brief',
      'text Chahel hi',
      'play hello on Spotify',
      "what's on my calendar",
      'set an alarm for 10:30pm',
      'open the maps app',
      'send an email to mom',
      'any news today',
      'turn on the flashlight',
    ]) {
      test('"$cmd" → escalate', () async {
        final res = await r.handle(cmd, VoiceSurface.chat);
        expect(res, isA<Escalate>(), reason: cmd);
        expect((res as Escalate).reason, 'server-request');
      });
    }
  });

  group('LocalRouter conversation stays local', () {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());

    for (final msg in [
      'hello',
      'who are you',
      'what can you do',
      'tell me a poem',
      'how are you',
      'good evening',
    ]) {
      test('"$msg" → DirectAnswer (local)', () async {
        expect(await r.handle(msg, VoiceSurface.chat), isA<DirectAnswer>(), reason: msg);
      });
    }
  });
}
