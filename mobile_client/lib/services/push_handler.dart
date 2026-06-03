import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../skills/common.dart' as common_skills;
import '../skills/registry.dart';
import 'api_client.dart';
import 'credentials.dart';
import 'invoke_runner.dart';
import 'poll_body.dart';
import 'ws_bridge.dart';

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

  /// Drain any queued server commands now (e.g. on app resume). Public
  /// wrapper so the app-lifecycle observer can flush the queue the moment
  /// the app comes back to the foreground.
  Future<void> drainNow() => _drainQueue();

  /// Pull queued invokes from the server, execute them, post results. This is
  /// the FOREGROUND drain (app is in front, e.g. resumed or a notification tap),
  /// so it asks for foreground-required invokes too.
  Future<void> _drainQueue() async {
    try {
      final pollResp =
          await api.postJson('/api/devices/mobile/poll', pollBody(foreground: true));
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
  // A Flutter binding is needed for plugin platform channels to work in
  // this background isolate (best-effort — UI-bound skills still won't run).
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('FCM background: ${msg.data}');

  await Credentials.instance.load();
  if (!Credentials.instance.isPaired) return;

  // The background isolate has its own memory, so the skill registry and
  // service singletons from main() don't exist here — rebuild them.
  registerCommonSkills(common_skills.everything);
  final bgApi = ApiClient();
  final bgRunner = InvokeRunner(api: bgApi, ws: WsBridge(api: bgApi));

  // Drain the server's queued commands within the OS background budget
  // (~30s on iOS). Skills that need the foreground/UI return an error,
  // which the server surfaces back to the agent — strictly better than
  // the previous no-op that only worked when the user opened the app.
  try {
    // BACKGROUND drain: ask the server to WITHHOLD foreground-required invokes
    // (they can't run headless — they wait for the visible-push tap to bring
    // the app forward).
    final pollResp = await bgApi.postJson(
        '/api/devices/mobile/poll', pollBody(foreground: false));
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
      // Defense-in-depth: a foreground-required action (openURL / a Shortcut)
      // can't run in this background isolate. The server already withholds them
      // from a foreground:false poll, but if one ever slips through, skip it so
      // we never fire a doomed headless openURL — it waits for the visible-push
      // tap to bring the app forward.
      if (raw['requires_foreground'] == true) continue;
      final r = await bgRunner.run(skill, args);
      try {
        await bgApi.postJson('/api/devices/mobile/result', {
          'call_id': callId,
          if (r.error != null) 'error': r.error,
          if (r.error == null) 'result': r.result,
        });
      } catch (e) {
        debugPrint('bg: failed to post result: $e');
      }
    }
  } catch (e) {
    debugPrint('bg drain failed: $e');
  }
}
