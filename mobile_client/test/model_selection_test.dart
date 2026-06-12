import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/model_selection.dart';
import 'package:jarviscopilot_mobile/services/on_device_ai_types.dart';

/// flutter_secure_storage 9.x drives everything over this MethodChannel
/// (verified from the package source:
/// flutter_secure_storage_platform_interface .../method_channel_flutter_secure_storage.dart).
/// We back it with an in-memory map so ModelSelection's secure-storage calls
/// round-trip in a plain `flutter test` (no platform).
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = <String, String>{};

  setUp(() {
    store.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          store[key!] = args['value'] as String;
          return null;
        case 'read':
          return store[key];
        case 'delete':
          store.remove(key);
          return null;
        case 'deleteAll':
          store.clear();
          return null;
        case 'containsKey':
          return store.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(store);
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('setFor / modelFor round-trips per surface', () async {
    final sel = ModelSelection.instance;
    await sel.clear();

    await sel.setFor(
      VoiceSurface.chat,
      model: 'anthropic/claude-opus-4.7',
      provider: 'anthropic',
    );

    expect(sel.modelFor(VoiceSurface.chat), 'anthropic/claude-opus-4.7');
    expect(sel.providerFor(VoiceSurface.chat), 'anthropic');

    // Survives a fresh load() (i.e. it actually persisted to the store).
    final reloaded = ModelSelection.instance;
    await reloaded.load();
    expect(reloaded.modelFor(VoiceSurface.chat), 'anthropic/claude-opus-4.7');
    expect(reloaded.providerFor(VoiceSurface.chat), 'anthropic');
  });

  test('chat and voice selections are independent', () async {
    final sel = ModelSelection.instance;
    await sel.clear();

    await sel.setFor(
      VoiceSurface.chat,
      model: 'anthropic/claude-opus-4.7',
      provider: 'anthropic',
    );
    await sel.setFor(
      VoiceSurface.voice,
      model: 'openai/gpt-5.4-mini',
      provider: 'openai',
    );

    expect(sel.modelFor(VoiceSurface.chat), 'anthropic/claude-opus-4.7');
    expect(sel.providerFor(VoiceSurface.chat), 'anthropic');
    expect(sel.modelFor(VoiceSurface.voice), 'openai/gpt-5.4-mini');
    expect(sel.providerFor(VoiceSurface.voice), 'openai');

    // Reassigning one surface must not touch the other.
    await sel.setFor(
      VoiceSurface.voice,
      model: 'google/gemini-2.5-flash',
      provider: 'google',
    );
    expect(sel.modelFor(VoiceSurface.chat), 'anthropic/claude-opus-4.7');
    expect(sel.modelFor(VoiceSurface.voice), 'google/gemini-2.5-flash');
  });

  test('getters return null before load / after clear', () async {
    final sel = ModelSelection.instance;
    await sel.clear();

    expect(sel.modelFor(VoiceSurface.chat), isNull);
    expect(sel.providerFor(VoiceSurface.chat), isNull);
    expect(sel.modelFor(VoiceSurface.voice), isNull);
    expect(sel.providerFor(VoiceSurface.voice), isNull);

    await sel.setFor(
      VoiceSurface.chat,
      model: 'anthropic/claude-opus-4.7',
      provider: 'anthropic',
    );
    await sel.clear();
    await sel.load();
    expect(sel.modelFor(VoiceSurface.chat), isNull);
    expect(sel.providerFor(VoiceSurface.chat), isNull);
  });

  test('passing null clears a previously-set field', () async {
    final sel = ModelSelection.instance;
    await sel.clear();

    await sel.setFor(
      VoiceSurface.chat,
      model: 'anthropic/claude-opus-4.7',
      provider: 'anthropic',
    );
    expect(sel.modelFor(VoiceSurface.chat), isNotNull);

    await sel.setFor(VoiceSurface.chat, model: null, provider: null);
    expect(sel.modelFor(VoiceSurface.chat), isNull);
    expect(sel.providerFor(VoiceSurface.chat), isNull);

    // And it really cleared the persisted value.
    await sel.load();
    expect(sel.modelFor(VoiceSurface.chat), isNull);
  });
}
