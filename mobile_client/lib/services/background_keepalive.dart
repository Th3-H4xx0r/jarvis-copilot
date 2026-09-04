import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_lifecycle.dart';
import 'credentials.dart';

/// Pure arm/disarm decision (plan Workstream H). Kept free of platform
/// channels and Flutter bindings so it's trivially unit-testable.
///
/// Armed only while:
///  - the user has the setting on (`enabled`)
///  - the device is paired to a server (`paired`) — no point holding a
///    silent audio session with nothing to talk to
///  - the app is actually backgrounded (`background`) — foregrounded, the
///    normal WS is already live and a hidden audio session would just be
///    background battery drain for nothing
///  - the voice controller is NOT already active (`voiceActive`) — it
///    configures its own AVAudioSession for recording; fighting over the
///    session (two `setCategory` calls) is worse than either alone, and
///    voice recording already keeps the process alive by itself.
bool computeKeepaliveArmed({
  required bool enabled,
  required bool paired,
  required bool background,
  required bool voiceActive,
}) =>
    enabled && paired && background && !voiceActive;

/// Drives the native silent-audio-session keepalive (see
/// `ios/Runner/BackgroundKeepaliveBridge.swift`) from the Dart side. Only
/// calls into the platform channel when the computed armed state actually
/// changes, so callers can invoke [sync] freely (on every lifecycle tick,
/// every WS connect/disconnect) without spamming `MethodChannel`.
///
/// No-op on non-iOS platforms — Android already has `BridgeService` keeping
/// the WS alive in the background.
class BackgroundKeepalive {
  BackgroundKeepalive._({
    Future<void> Function(bool active)? setActive,
    KeepaliveSettingsStore? store,
  })  : _setActiveImpl = setActive ?? _platformSetActive,
        _store = store ?? SecureKeepaliveSettingsStore();

  // The singleton wires itself to AppLifecycle so a foreground/background
  // edge (main.dart's `AppLifecycle.isForeground = ...`) or a voice-session
  // edge (voice_controller's `AppLifecycle.voiceActive = ...`, see
  // app_lifecycle.dart) automatically re-syncs. Test instances (`forTest`)
  // deliberately skip this — they exercise `sync`/`setVoiceActive` directly.
  static final BackgroundKeepalive instance = BackgroundKeepalive._().._wireLifecycle();

  void _wireLifecycle() {
    AppLifecycle.addListener(() {
      unawaited(syncFromAppState());
    });
  }

  /// Test seam: inject a fake `setActive` so decision-coalescing can be
  /// verified without a platform channel / iOS runtime.
  factory BackgroundKeepalive.forTest({
    required Future<void> Function(bool active) setActive,
    KeepaliveSettingsStore? store,
  }) =>
      BackgroundKeepalive._(setActive: setActive, store: store);

  static const MethodChannel _channel =
      MethodChannel('jarviscopilot/keepalive');

  final Future<void> Function(bool active) _setActiveImpl;
  final KeepaliveSettingsStore _store;

  bool? _lastArmed;
  bool _voiceActive = false;

  // Last known inputs, so setVoiceActive() (called from the voice
  // controller's lifecycle hook, not on a background/foreground edge) can
  // re-evaluate without the caller having to re-supply everything.
  bool _lastEnabled = true;
  bool _lastPaired = false;
  bool _lastBackground = false;

  static Future<void> _platformSetActive(bool active) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setActive', {'active': active});
    } catch (_) {
      // Best-effort: a missing/failed channel just means push stays the
      // fallback path, same as before this feature existed.
    }
  }

  /// Whether the setting is on. Defaults to true on iOS (per spec), false
  /// elsewhere (no-op platform).
  Future<bool> isEnabled() => _store.readEnabled();

  Future<void> setEnabled(bool v) async {
    await _store.writeEnabled(v);
    await sync(
      enabled: v,
      paired: _lastPaired,
      background: _lastBackground,
      voiceActive: _voiceActive,
    );
  }

  /// Recomputes the armed state from the given inputs and (only if it
  /// changed) calls the platform channel. Call this on every WS
  /// connect/disconnect and every foreground/background transition.
  Future<void> sync({
    required bool enabled,
    required bool paired,
    required bool background,
    required bool voiceActive,
  }) async {
    _lastEnabled = enabled;
    _lastPaired = paired;
    _lastBackground = background;
    _voiceActive = voiceActive;
    final armed = computeKeepaliveArmed(
      enabled: enabled,
      paired: paired,
      background: background,
      voiceActive: voiceActive,
    );
    if (armed == _lastArmed) return;
    _lastArmed = armed;
    await _setActiveImpl(armed);
  }

  /// Called from the voice controller's lifecycle hook (via
  /// `AppLifecycle.voiceActive = true/false`, see app_lifecycle.dart) when a
  /// voice session starts/stops. Re-evaluates using the last known
  /// enabled/paired/background inputs.
  Future<void> setVoiceActive(bool active) => sync(
        enabled: _lastEnabled,
        paired: _lastPaired,
        background: _lastBackground,
        voiceActive: active,
      );

  /// Convenience: pulls `paired` from [Credentials] and `background` from
  /// [AppLifecycle], reads the persisted setting, and syncs. Call this from
  /// ws_bridge.dart on connect/disconnect and from the app lifecycle
  /// observer on foreground/background transitions.
  Future<void> syncFromAppState() async {
    final enabled = await isEnabled();
    await sync(
      enabled: enabled,
      paired: Credentials.instance.isPaired,
      background: !AppLifecycle.isForeground,
      voiceActive: AppLifecycle.voiceActive,
    );
  }
}

/// Tiny key-value seam so the setting is unit-testable without a platform
/// channel — mirrors `LocalAiSettings`'s `KvStore` pattern.
abstract interface class KeepaliveSettingsStore {
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool v);
}

class SecureKeepaliveSettingsStore implements KeepaliveSettingsStore {
  static const _key = 'keepalive_enabled';

  // Mirrors Credentials/LocalAiSettings: Keychain on iOS, EncryptedSharedPreferences
  // on Android.
  static const FlutterSecureStorage _store = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  @override
  Future<bool> readEnabled() async {
    if (!Platform.isIOS) return false; // Android: BridgeService handles it
    final raw = await _store.read(key: _key);
    if (raw == null) return true; // default ON on iOS
    return raw == '1';
  }

  @override
  Future<void> writeEnabled(bool v) => _store.write(key: _key, value: v ? '1' : '0');
}
