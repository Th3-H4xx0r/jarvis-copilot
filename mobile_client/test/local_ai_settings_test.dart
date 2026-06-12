import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_ai_settings.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';

class _MemKv implements KvStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _m.remove(key);
    } else {
      _m[key] = value;
    }
  }
}

void main() {
  test('defaults are off / server', () {
    final s = LocalAiSettings(store: _MemKv());
    expect(s.tier, LocalAiTier.off);
    expect(s.enabledForChat, isFalse);
    expect(s.enabledForVoice, isFalse);
    expect(s.activeLocalModelId, 'apple-fm');
    expect(s.deadlineMs, 700);
  });

  test('save then load round-trips every field', () async {
    final kv = _MemKv();
    final a = LocalAiSettings(store: kv)
      ..tier = LocalAiTier.fullLocalFirst
      ..chatEnabled = true
      ..voiceEnabled = true
      ..activeLocalModelId = 'mlx-community/Qwen2.5-1.5B-Instruct-4bit'
      ..deadlineMs = 900
      ..confidenceFloor = 0.7
      ..confirmLocalActions = false
      ..commandShortCircuit = false
      ..showBadge = false;
    await a.save();

    final b = LocalAiSettings(store: kv);
    await b.load();
    expect(b.tier, LocalAiTier.fullLocalFirst);
    expect(b.chatEnabled, isTrue);
    expect(b.voiceEnabled, isTrue);
    expect(b.activeLocalModelId, 'mlx-community/Qwen2.5-1.5B-Instruct-4bit');
    expect(b.deadlineMs, 900);
    expect(b.confidenceFloor, 0.7);
    expect(b.confirmLocalActions, isFalse);
    expect(b.commandShortCircuit, isFalse);
    expect(b.showBadge, isFalse);
    expect(b.enabledForChat, isTrue);
  });

  test('enabledFor honors tier off even when surface enabled', () async {
    final s = LocalAiSettings(store: _MemKv())
      ..tier = LocalAiTier.off
      ..chatEnabled = true;
    expect(s.enabledFor(VoiceSurface.chat), isFalse);
  });
}
