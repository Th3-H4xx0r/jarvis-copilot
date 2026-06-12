import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'on_device_ai_types.dart';

/// Tiny key-value seam so settings persistence is unit-testable without
/// platform channels. Defaults to secure storage (mirrors Credentials).
abstract interface class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class SecureKvStore implements KvStore {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String? value) =>
      _s.write(key: key, value: value);
}

/// Persisted configuration for the on-device AI layer. The fields are plain
/// mutable values so tests (and the Settings UI) can read/write them directly;
/// [load]/[save] handle durability.
class LocalAiSettings {
  LocalAiSettings({KvStore? store}) : _store = store ?? SecureKvStore();

  final KvStore _store;

  static final LocalAiSettings instance = LocalAiSettings();

  // ── State (with safe defaults = off / server) ──
  LocalAiTier tier = LocalAiTier.off;
  bool chatEnabled = false;
  bool voiceEnabled = false;
  String activeLocalModelId = 'apple-fm';

  /// Minimum self-reported confidence to accept a local decision. Default 0 —
  /// the MODEL decides (via its `action`); confidence never forces escalation
  /// unless the user raises this.
  double confidenceFloor = 0.0;

  /// Confirm destructive/outward actions before running them locally.
  bool confirmLocalActions = true;

  /// Let device-commands short-circuit even when a server model is picked.
  bool commandShortCircuit = true;

  /// Show the "on-device" badge on locally-handled replies.
  bool showBadge = true;

  bool get enabledForChat => tier != LocalAiTier.off && chatEnabled;
  bool get enabledForVoice => tier != LocalAiTier.off && voiceEnabled;

  bool enabledFor(VoiceSurface surface) =>
      surface == VoiceSurface.chat ? enabledForChat : enabledForVoice;

  static const _kTier = 'lai_tier';
  static const _kChat = 'lai_chat';
  static const _kVoice = 'lai_voice';
  static const _kModel = 'lai_model';
  static const _kConf = 'lai_conf';
  static const _kConfirm = 'lai_confirm';
  static const _kShort = 'lai_short';
  static const _kBadge = 'lai_badge';

  Future<void> load() async {
    tier = LocalAiTierCodec.parse(await _store.read(_kTier));
    chatEnabled = (await _store.read(_kChat)) == '1';
    voiceEnabled = (await _store.read(_kVoice)) == '1';
    activeLocalModelId = (await _store.read(_kModel)) ?? 'apple-fm';
    confidenceFloor =
        double.tryParse(await _store.read(_kConf) ?? '') ?? 0.0;
    // Defaults true unless explicitly stored '0'.
    confirmLocalActions = (await _store.read(_kConfirm)) != '0';
    commandShortCircuit = (await _store.read(_kShort)) != '0';
    showBadge = (await _store.read(_kBadge)) != '0';
  }

  Future<void> save() async {
    await _store.write(_kTier, tier.wire);
    await _store.write(_kChat, chatEnabled ? '1' : '0');
    await _store.write(_kVoice, voiceEnabled ? '1' : '0');
    await _store.write(_kModel, activeLocalModelId);
    await _store.write(_kConf, '$confidenceFloor');
    await _store.write(_kConfirm, confirmLocalActions ? '1' : '0');
    await _store.write(_kShort, commandShortCircuit ? '1' : '0');
    await _store.write(_kBadge, showBadge ? '1' : '0');
  }
}
