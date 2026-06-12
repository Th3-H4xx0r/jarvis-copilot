import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skills/action_banner.dart';
import '../skills/common.dart' show showLocalNotification;
import '../skills/registry.dart';
import 'api_client.dart';
import 'app_lifecycle.dart';
import 'credentials.dart';
import 'pending_actions.dart';
import 'ws_bridge.dart';

/// Result envelope returned by [InvokeRunner.run].
class InvokeResult {
  InvokeResult.ok(this.result) : error = null;
  InvokeResult.err(this.error) : result = null;
  final Object? result;
  final String? error;
}

/// True when a local tool ran WITHOUT throwing but didn't achieve its effect —
/// today only `open_app`, which returns `{launched:false}` when iOS has no URL
/// scheme for the requested app (e.g. many bank apps). The local matcher path
/// uses this to escalate to the server (which can supply a known scheme or
/// answer honestly) instead of speaking a fabricated "Opening X". A THROWN error
/// (res.error set) is not a "miss" — it's surfaced normally.
bool localToolMissed(String name, InvokeResult res) {
  if (res.error != null) return false;
  if (name == 'open_app') {
    final r = res.result;
    return r is Map && r['launched'] == false;
  }
  return false;
}

/// Central skill dispatch. Whether the invoke arrived via the WS bridge
/// or via the silent-push poll path, both call into here so:
///
/// - disabled-skill ACLs are enforced in one place
/// - logging / metrics live in one place
/// - the foreground UI can pause execution via a single flag
class InvokeRunner {
  InvokeRunner({required this.api, required this.ws});
  final ApiClient api;
  final WsBridge ws;

  /// When true, every invoke returns {error:"paused"} without touching
  /// the skill. The Settings page toggles this.
  final ValueNotifier<bool> paused = ValueNotifier(false);

  /// Most-recent invocations, newest first. Bounded — the Logs page
  /// reads this to show history without paging from the server.
  final List<InvokeLog> log = [];
  static const int _logCap = 200;

  Future<InvokeResult> run(String skillName, Map<String, dynamic> args) async {
    if (paused.value) {
      _append(InvokeLog(skillName, args, error: 'paused'));
      return InvokeResult.err('paused');
    }
    if (Credentials.instance.skillsDisabled.contains(skillName)) {
      _append(InvokeLog(skillName, args, error: 'disabled'));
      return InvokeResult.err('skill disabled by user');
    }
    final entry = SkillRegistry.instance.find(skillName);
    if (entry == null) {
      _append(InvokeLog(skillName, args, error: 'unknown skill'));
      return InvokeResult.err('unknown skill: $skillName');
    }
    // A foreground-required action (openURL / launch an app) can't run while the
    // app is backgrounded — iOS refuses it. The app stays alive in the
    // background (audio/location modes), so instead of failing we DEFER: stash
    // the action, post a LOCAL notification, and run it when the user taps (the
    // app foregrounds → main.dart drains PendingActions). This needs no remote
    // push, so it works regardless of FCM/APNs delivery.
    if (shouldDeferToForeground(
        requiresForeground: entry.requiresForeground,
        isForeground: AppLifecycle.isForeground)) {
      PendingActions.instance.add(skillName, args);
      unawaited(
          showLocalNotification(actionBannerTitle(skillName, args), 'Tap to run'));
      _append(InvokeLog(skillName, args, result: 'deferred to foreground'));
      return InvokeResult.ok({
        'queued': true,
        'note': 'Sent to your phone — tap the notification to run it.',
      });
    }
    try {
      final result = await entry.run(args);
      _append(InvokeLog(skillName, args, result: result));
      return InvokeResult.ok(result);
    } catch (e, st) {
      debugPrint('skill $skillName raised: $e\n$st');
      _append(InvokeLog(skillName, args, error: '$e'));
      return InvokeResult.err('${e.runtimeType}: $e');
    }
  }

  void _append(InvokeLog entry) {
    log.insert(0, entry);
    if (log.length > _logCap) {
      log.removeRange(_logCap, log.length);
    }
  }
}

class InvokeLog {
  InvokeLog(this.skill, this.args, {this.result, this.error})
      : at = DateTime.now();
  final String skill;
  final Map<String, dynamic> args;
  final Object? result;
  final String? error;
  final DateTime at;
}
