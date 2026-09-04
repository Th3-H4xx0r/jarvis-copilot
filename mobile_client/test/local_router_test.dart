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
      'play hello on Spotify',
      "what's on my calendar",
      'set an alarm for 10:30pm',
      'send an email to mom',
      'any news today',
      'open Spotify on my Mac', // cross-device → server
    ]) {
      test('"$cmd" → escalate', () async {
        final res = await r.handle(cmd, VoiceSurface.chat);
        expect(res, isA<Escalate>(), reason: cmd);
        expect((res as Escalate).reason, 'server-request');
      });
    }
  });

  group('LocalRouter instant local commands', () {
    final r = LocalRouter(ai: _FakeAi(), settings: _settings());

    test('"open Spotify" → ToolCall open_app (this device)', () async {
      final res = await r.handle('open Spotify', VoiceSurface.chat);
      expect(res, isA<ToolCall>());
      final tc = res as ToolCall;
      expect(tc.name, 'open_app');
      expect(tc.args['name'], 'Spotify');
    });

    test('"turn on the flashlight" → ToolCall', () async {
      final res = await r.handle('turn on the flashlight', VoiceSurface.chat);
      expect(res, isA<ToolCall>());
      expect((res as ToolCall).name, 'flashlight_on');
    });

    test('"vibrate" → ToolCall', () async {
      expect(((await r.handle('vibrate', VoiceSurface.chat)) as ToolCall).name, 'vibrate');
    });

    test('"set volume to 30" → phone_control (not the Android set_volume)', () async {
      final tc = await r.handle('set volume to 30', VoiceSurface.chat) as ToolCall;
      expect(tc.name, 'phone_control');
      expect(tc.args['action'], 'volume');
      expect(tc.args['value'], '30');
    });

    test('"text Chahel hi" → phone_control send_message (local Shortcut)', () async {
      final tc = await r.handle('text Chahel hi', VoiceSurface.chat) as ToolCall;
      expect(tc.name, 'phone_control');
      expect(tc.args['action'], 'send_message');
      expect(tc.args['to'], 'Chahel');
      expect(tc.args['message'], 'hi');
    });
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

