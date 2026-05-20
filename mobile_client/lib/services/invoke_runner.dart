import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skills/registry.dart';
import 'api_client.dart';
import 'credentials.dart';
import 'ws_bridge.dart';

/// Result envelope returned by [InvokeRunner.run].
class InvokeResult {
  InvokeResult.ok(this.result) : error = null;
  InvokeResult.err(this.error) : result = null;
  final Object? result;
  final String? error;
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
