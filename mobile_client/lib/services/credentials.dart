import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistent credentials for the paired session. Keychain on iOS,
/// EncryptedSharedPreferences on Android. We hold:
///
/// - server_url:        the webui base ("https://1.2.3.4:8787")
/// - cookie:            hermes_session=… (issued by /api/auth/pair/claim)
/// - cert_fingerprint:  SHA-256 of the server's leaf TLS cert at first pair
/// - device_name:       user-facing label shown in the Devices tab
/// - device_id:         server-issued UUID (from /devices/mobile/token)
/// - allow_shell:       opt-in for the (Android-only) shell execution skill
/// - skills_disabled:   JSON array of skill names the user has toggled off
/// - push_token:        last token we registered with the server
class Credentials {
  Credentials._();
  static final Credentials instance = Credentials._();

  // ignore: prefer_const_declarations
  static final FlutterSecureStorage _store = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  String? serverUrl;
  String? cookie;
  String? certFingerprint;
  String? deviceName;
  String? deviceId;
  // Cloudflare Access service token (for tunnel exposure). Sent as
  // CF-Access-Client-Id / CF-Access-Client-Secret to clear Access at the edge.
  // Empty when not behind a tunnel — headers are then simply not added.
  String? cfClientId;
  String? cfClientSecret;
  bool allowShell = false;
  // Opt-in background location history + connection keep-alive.
  bool trackLocation = false;
  // Show coding sessions on the Lock Screen / Dynamic Island (default on).
  bool liveActivitiesEnabled = true;
  Set<String> skillsDisabled = {};
  String? pushToken;

  bool get isPaired => (serverUrl?.isNotEmpty ?? false) && (cookie?.isNotEmpty ?? false);

  Future<void> load() async {
    serverUrl = await _store.read(key: 'server_url');
    cookie = await _store.read(key: 'cookie');
    certFingerprint = await _store.read(key: 'cert_fingerprint');
    deviceName = await _store.read(key: 'device_name');
    deviceId = await _store.read(key: 'device_id');
    cfClientId = await _store.read(key: 'cf_client_id');
    cfClientSecret = await _store.read(key: 'cf_client_secret');
    allowShell = (await _store.read(key: 'allow_shell')) == '1';
    trackLocation = (await _store.read(key: 'track_location')) == '1';
    // Default-on: a missing key means enabled (only an explicit '0' disables).
    liveActivitiesEnabled = (await _store.read(key: 'live_activities')) != '0';
    final raw = await _store.read(key: 'skills_disabled');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = json.decode(raw) as List;
        skillsDisabled = list.map((e) => e.toString()).toSet();
      } catch (_) {
        skillsDisabled = {};
      }
    }
    pushToken = await _store.read(key: 'push_token');
  }

  Future<void> savePairing({
    required String serverUrl,
    required String cookie,
    required String certFingerprint,
    required String deviceName,
  }) async {
    this.serverUrl = serverUrl;
    this.cookie = cookie;
    this.certFingerprint = certFingerprint;
    this.deviceName = deviceName;
    await _store.write(key: 'server_url', value: serverUrl);
    await _store.write(key: 'cookie', value: cookie);
    await _store.write(key: 'cert_fingerprint', value: certFingerprint);
    await _store.write(key: 'device_name', value: deviceName);
  }

  /// Persist (or clear, when both empty) the Cloudflare Access service token.
  Future<void> saveCfToken(String? clientId, String? clientSecret) async {
    cfClientId = (clientId?.isNotEmpty ?? false) ? clientId : null;
    cfClientSecret = (clientSecret?.isNotEmpty ?? false) ? clientSecret : null;
    if (cfClientId != null) {
      await _store.write(key: 'cf_client_id', value: cfClientId!);
    } else {
      await _store.delete(key: 'cf_client_id');
    }
    if (cfClientSecret != null) {
      await _store.write(key: 'cf_client_secret', value: cfClientSecret!);
    } else {
      await _store.delete(key: 'cf_client_secret');
    }
  }

  /// Cloudflare Access headers to attach to every request, or empty when the
  /// service token isn't configured (local / non-tunnel use).
  Map<String, String> get cfAccessHeaders {
    final id = cfClientId, secret = cfClientSecret;
    if (id != null && id.isNotEmpty && secret != null && secret.isNotEmpty) {
      return {'CF-Access-Client-Id': id, 'CF-Access-Client-Secret': secret};
    }
    return const {};
  }

  Future<void> savePushToken(String token) async {
    pushToken = token;
    await _store.write(key: 'push_token', value: token);
  }

  Future<void> saveDeviceId(String id) async {
    deviceId = id;
    await _store.write(key: 'device_id', value: id);
  }

  Future<void> saveTrackLocation(bool value) async {
    trackLocation = value;
    await _store.write(key: 'track_location', value: value ? '1' : '0');
  }

  Future<void> saveLiveActivities(bool value) async {
    liveActivitiesEnabled = value;
    await _store.write(key: 'live_activities', value: value ? '1' : '0');
  }

  Future<void> saveAllowShell(bool value) async {
    allowShell = value;
    await _store.write(key: 'allow_shell', value: value ? '1' : '0');
  }

  Future<void> saveSkillsDisabled(Set<String> names) async {
    skillsDisabled = names;
    await _store.write(
      key: 'skills_disabled',
      value: json.encode(names.toList()),
    );
  }

  Future<void> clear() async {
    serverUrl = null;
    cookie = null;
    certFingerprint = null;
    deviceName = null;
    deviceId = null;
    cfClientId = null;
    cfClientSecret = null;
    pushToken = null;
    skillsDisabled = {};
    await _store.deleteAll();
  }
}
