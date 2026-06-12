import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'on_device_ai_types.dart';

/// Per-surface choice of the SERVER model/provider. Chat and Voice each keep
/// their own selection so you can run (say) a fast model for voice and a
/// stronger one for chat. Persisted in secure storage, mirroring
/// [Credentials]'s pattern (Keychain on iOS, EncryptedSharedPreferences on
/// Android).
///
/// A null value for either field means "no explicit override" — the caller
/// should then fall back to the server's active/default model.
///
/// Keys:
///   - sel_chat_model     / sel_chat_provider
///   - sel_voice_model    / sel_voice_provider
class ModelSelection {
  ModelSelection._();
  static final ModelSelection instance = ModelSelection._();

  // ignore: prefer_const_declarations
  static final FlutterSecureStorage _store = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  String? chatModel;
  String? chatProvider;
  String? voiceModel;
  String? voiceProvider;

  static String _modelKey(VoiceSurface s) =>
      s == VoiceSurface.voice ? 'sel_voice_model' : 'sel_chat_model';
  static String _providerKey(VoiceSurface s) =>
      s == VoiceSurface.voice ? 'sel_voice_provider' : 'sel_chat_provider';

  /// Load the persisted selections. Safe to call once at startup; the getters
  /// return null before [load] completes (i.e. read-before-load is fine).
  Future<void> load() async {
    chatModel = await _store.read(key: 'sel_chat_model');
    chatProvider = await _store.read(key: 'sel_chat_provider');
    voiceModel = await _store.read(key: 'sel_voice_model');
    voiceProvider = await _store.read(key: 'sel_voice_provider');
  }

  /// The selected model id for [surface], or null when none is set.
  String? modelFor(VoiceSurface surface) =>
      surface == VoiceSurface.voice ? voiceModel : chatModel;

  /// The selected provider id for [surface], or null when none is set.
  String? providerFor(VoiceSurface surface) =>
      surface == VoiceSurface.voice ? voiceProvider : chatProvider;

  /// Persist a new selection for [surface]. A null argument clears that field.
  ///
  /// Pass both [model] and [provider] together when picking a concrete model —
  /// they always travel as a pair from the picker.
  Future<void> setFor(
    VoiceSurface surface, {
    String? model,
    String? provider,
  }) async {
    if (surface == VoiceSurface.voice) {
      voiceModel = model;
      voiceProvider = provider;
    } else {
      chatModel = model;
      chatProvider = provider;
    }
    await _put(_modelKey(surface), model);
    await _put(_providerKey(surface), provider);
  }

  /// Clear every persisted selection (e.g. on un-pair).
  Future<void> clear() async {
    chatModel = null;
    chatProvider = null;
    voiceModel = null;
    voiceProvider = null;
    await _store.delete(key: 'sel_chat_model');
    await _store.delete(key: 'sel_chat_provider');
    await _store.delete(key: 'sel_voice_model');
    await _store.delete(key: 'sel_voice_provider');
  }

  static Future<void> _put(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _store.delete(key: key);
    } else {
      await _store.write(key: key, value: value);
    }
  }
}
