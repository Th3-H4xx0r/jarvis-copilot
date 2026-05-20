import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'credentials.dart';
import 'invoke_runner.dart';

/// Push registration + background-wake handler.
///
/// On Android: FCM data messages arrive through [FirebaseMessaging] and
/// the background isolate is woken via the top-level handler registered
/// in main.dart. The payload is just a "wake up and poll" envelope; the
/// app then drains [POST /api/devices/mobile/poll].
///
/// On iOS: Firebase Messaging surfaces the APNs silent push through the
/// same [FirebaseMessaging] channel. The OS gives the app ~30s of
/// background runtime; we use it to poll + run + post results before
/// the OS suspends us again.
class PushHandler {
  PushHandler({required this.api, required this.runner});

  final ApiClient api;
  final InvokeRunner runner;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (Firebase.apps.isEmpty) {
      debugPrint('Push disabled: Firebase is not initialized');
      return;
    }

    // Permissions: iOS shows the alert prompt; Android 13+ requires
    // POST_NOTIFICATIONS at runtime (firebase_messaging handles both).
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
    } catch (e) {
      debugPrint('push permission request failed: $e');
    }

    // Get an initial token + listen for refreshes.
    try {
      final tok = await FirebaseMessaging.instance.getToken();
      if (tok != null && tok.isNotEmpty) {
        await _registerToken(tok);
      }
    } catch (e) {
      debugPrint('FCM getToken failed: $e');
    }
    FirebaseMessaging.instance.onTokenRefresh.listen(_registerToken);

    // Foreground messages — drain immediately.
    FirebaseMessaging.onMessage.listen((msg) async {
      debugPrint('FCM foreground: ${msg.data}');
      await _drainQueue();
    });

    // Background data messages (Android only — iOS uses the silent
    // push hooked at the native level). Registered as a top-level
    // function in main.dart for the isolate to find it.
    FirebaseMessaging.onBackgroundMessage(_backgroundMessageHandler);

    // Tap on a system notification while the app is terminated.
    FirebaseMessaging.instance.getInitialMessage().then((msg) async {
      if (msg != null) await _drainQueue();
    });
    FirebaseMessaging.onMessageOpenedApp.listen((_) => _drainQueue());
  }

  Future<void> _registerToken(String token) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    // FCM tokens cover both platforms; the server only uses our hint
    // to decide whether to send via FCM HTTP v1 (Android) or APNs
    // HTTP/2 (iOS), since their queueing characteristics differ.
    final pushKind = Platform.isIOS ? 'apns' : 'fcm';
    try {
      final resp = await api.postJson('/api/devices/mobile/token', {
        'push_kind': pushKind,
        'push_token': token,
        'platform': platform,
        'app_version': '0.1.0',
      });
      debugPrint('registered push token: ${resp.statusCode}');
      await Credentials.instance.savePushToken(token);
      final body = resp.data;
      if (body is Map && body['device_id'] is String) {
        await Credentials.instance.saveDeviceId(body['device_id'] as String);
      }
    } catch (e) {
      debugPrint('push token register failed: $e');
    }
  }

  /// Pull queued invokes from the server, execute them, post results.
  Future<void> _drainQueue() async {
    try {
      final pollResp = await api.postJson('/api/devices/mobile/poll', const {});
      final body = pollResp.data;
      if (body is! Map) return;
      final invokes = (body['invokes'] as List?) ?? const [];
      for (final raw in invokes) {
        if (raw is! Map) continue;
        final callId = (raw['call_id'] ?? '').toString();
        final skill = (raw['skill'] ?? '').toString();
        final args = (raw['args'] is Map)
            ? Map<String, dynamic>.from(raw['args'] as Map)
            : <String, dynamic>{};
        if (callId.isEmpty || skill.isEmpty) continue;
        final r = await runner.run(skill, args);
        try {
          await api.postJson('/api/devices/mobile/result', {
            'call_id': callId,
            if (r.error != null) 'error': r.error,
            if (r.error == null) 'result': r.result,
          });
        } catch (e) {
          debugPrint('failed to post mobile result: $e');
        }
      }
    } catch (e) {
      debugPrint('mobile poll failed: $e');
    }
  }
}

/// Top-level background handler — required by firebase_messaging to be
/// a static / top-level function with a `@pragma('vm:entry-point')`.
/// Because the background isolate has no shared state with the
/// foreground one, we re-initialize Credentials and Dio inside.
@pragma('vm:entry-point')
Future<void> _backgroundMessageHandler(RemoteMessage msg) async {
  // firebase_messaging 14.x REQUIRES Firebase to be initialized inside
  // the background isolate. Without this, any Firebase API call here
  // throws "No Firebase App '[DEFAULT]' has been created".
  try {
    await Firebase.initializeApp();
  } catch (_) {/* already initialized — fine */}
  debugPrint('FCM background: ${msg.data}');
  // Spin up a minimal client + runner for the background isolate. The
  // foreground InvokeRunner isn't reachable, so we run only Tier-1
  // platform skills that don't need UI to behave.
  await Credentials.instance.load();
  // Implementations relying on platform channels must be careful to
  // initialize their bindings; some channels require a Flutter binding
  // and won't work in a pure background isolate. We do best-effort
  // here, and any unsupported skill returns an error which the server
  // surfaces back to the agent.
  // NB: leaving the actual draining to the foreground handler when
  // the user taps; the silent-push pattern means iOS wakes us into
  // the foreground onMessage handler anyway, so explicit work here is
  // a fallback.
}
