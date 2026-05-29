import 'dart:async';

import 'package:flutter/services.dart';

import 'credentials.dart';

/// Pushes the paired credentials down to the native iOS layer so the
/// Apple Watch bridge (`WatchBridge.swift`) can make backend calls on the
/// watch's behalf without the Flutter engine running — mirroring the
/// native background-location push (`background_location.dart` →
/// `jarviscopilot/location`).
///
/// Also carries the current login-state, which the native side forwards to
/// the watch via `WCSession.updateApplicationContext`, so the watch can show
/// its "set up on iPhone" screen before the user even taps.
///
/// No-op on platforms without the channel (Android): the
/// [MissingPluginException] is swallowed.
class WatchSync {
  static const _channel = MethodChannel('jarviscopilot/watch');

  /// Sync the current [Credentials] + login-state to the native watch bridge.
  /// Call after `Credentials.load()`, after a successful pair, and on logout.
  ///
  /// [retry] guards a one-shot retry: on a cold launch the post-first-frame
  /// call can race the native handler registration (done in
  /// `attachFlutterController`), surfacing as a [MissingPluginException]. We
  /// retry once shortly after; if the platform is genuinely unsupported
  /// (Android), the retry is a cheap no-op that also throws and stops.
  static Future<void> sync({bool retry = true}) async {
    final c = Credentials.instance;
    try {
      await _channel.invokeMethod('syncCredentials', {
        'serverUrl': c.serverUrl ?? '',
        'cookie': c.cookie ?? '',
        'certSha256': (c.certFingerprint ?? '').toLowerCase(),
        'loggedIn': c.isPaired,
      });
    } on MissingPluginException {
      if (retry) {
        Future.delayed(const Duration(milliseconds: 600), () => sync(retry: false));
      }
      // else: Android / unsupported platform — nothing to sync to.
    }
  }
}
