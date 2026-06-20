// Pure helpers for the offline plan embedded in a Dynamic Island design.

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

/// A stable content signature for a plan's notifications so the scheduler only
/// re-schedules when the list actually changes (the coordinator polls every ~5s).
String notificationsSignature(List<Map<String, dynamic>> notifications) {
  final parts = notifications.map((n) {
    final at = n['at'];
    final title = (n['title'] ?? '').toString();
    final body = (n['body'] ?? '').toString();
    return '$at$title$body';
  }).toList()
    ..sort();
  return parts.join('');
}
