// Pure helpers for the offline plan embedded in a Dynamic Island design.

import 'dart:convert';

/// Pick the data of the timeline keyframe in effect at [nowEpochSeconds] — the
/// entry with the greatest `at` ≤ now. Returns `{}` when the timeline is empty
/// or the earliest keyframe is still in the future. Keyframes need not be sorted;
/// malformed entries are skipped.
Map<String, dynamic> currentKeyframeData(
    List<Map<String, dynamic>> timeline, int nowEpochSeconds) {
  Map<String, dynamic> best = const {};
  num bestAt = double.negativeInfinity;
  var found = false;
  for (final kf in timeline) {
    final raw = kf['at'];
    final at = raw is num ? raw : (raw is String ? num.tryParse(raw) : null);
    if (at == null) continue;
    if (at <= nowEpochSeconds && at >= bestAt) {
      bestAt = at;
      final d = kf['data'];
      best = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
      found = true;
    }
  }
  return found ? best : const {};
}

/// A stable content signature for the unified scheduled items
/// `[{at,title,body,action?}]` (jobs + notifications) so the scheduler only
/// re-schedules when the list actually changes (the coordinator polls every
/// ~5s). Includes the `action` so a changed tap-action reschedules.
String scheduledItemsSignature(List<Map<String, dynamic>> items) {
  // Control-byte separators (SOH / STX) — these never appear in titles, bodies
  // or JSON, so fields/rows can't collide regardless of their content.
  const fieldSep = '\u0001';
  const rowSep = '\u0002';
  final parts = items.map((n) {
    final at = n['at'];
    final title = (n['title'] ?? '').toString();
    final body = (n['body'] ?? '').toString();
    final action = n['action'] != null ? jsonEncode(n['action']) : '';
    return '$at$fieldSep$title$fieldSep$body$fieldSep$action';
  }).toList()
    ..sort();
  return parts.join(rowSep);
}
