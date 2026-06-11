import 'package:flutter/services.dart';

import '../api/coding_sessions.dart';

/// Bridges iOS notification actions to the server. The native AppDelegate
/// forwards a tapped Approve/Deny/Reply on a permission-approval banner over the
/// `jarviscopilot/notification-actions` channel; we POST the verdict (or, for
/// Reply, a deny carrying the steering message). The in-app approval card is the
/// always-available fallback when a background action can't reach the engine.
class NotificationActions {
  NotificationActions(this._api);

  final CodingSessionsApi _api;
  static const MethodChannel _ch =
      MethodChannel('jarviscopilot/notification-actions');

  void start() {
    _ch.setMethodCallHandler(_handle);
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'permissionAction') return null;
    final a = Map<String, dynamic>.from((call.arguments as Map?) ?? const {});
    final requestId = (a['request_id'] ?? '').toString();
    final action = (a['action'] ?? '').toString();
    final text = (a['text'] ?? '').toString();
    if (requestId.isEmpty) return null;
    try {
      switch (action) {
        case 'allow':
          await _api.submitPermissionVerdict(requestId, decision: 'allow');
          break;
        case 'deny':
          await _api.submitPermissionVerdict(requestId, decision: 'deny');
          break;
        case 'reply':
          await _api.submitPermissionVerdict(requestId,
              decision: 'deny', message: text);
          break;
        // 'open' → the app foregrounds; the in-app approval card takes over.
      }
    } catch (_) {
      // best-effort; the in-app card lets the user retry
    }
    return null;
  }
}
