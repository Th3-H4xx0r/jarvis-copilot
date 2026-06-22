import '../services/api_client.dart';

/// REST wrapper for the WebUI usage analytics (`/api/insights`), the same data
/// that powers the web Insights panel: totals, per-model breakdown, a daily
/// token series and activity-by-day/hour histograms.
///
/// The backend (`_handle_insights` in webui/api/routes.py) returns, for a
/// `days` window (1..365):
///   {
///     period_days, total_sessions, total_messages,
///     total_input_tokens, total_output_tokens, total_tokens, total_cost,
///     models: [ {model, sessions, input_tokens, output_tokens,
///                total_tokens, cost, session_share, token_share,
///                cost_share}, ... ],          // sorted by cost desc
///     daily_tokens: [ {date, input_tokens, output_tokens, sessions, cost}, ... ],
///     activity_by_day:  [ {day:"Mon", sessions}, ... 7 ],
///     activity_by_hour: [ {hour:0..23, sessions}, ... 24 ],
///   }
///
/// Note: `models`, `daily_tokens`, `activity_by_*` are LISTS, not maps.
/// Everything is parsed defensively so a missing/renamed field never throws.
class InsightsApi {
  InsightsApi(this.api);
  final ApiClient api;

  /// GET /api/insights?days=N → the analytics map (raw, parsed defensively by
  /// the caller via the helpers below).
  Future<Map<String, dynamic>> overview({int days = 30}) async {
    final resp = await api.get('/api/insights', query: {'days': '$days'});
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// GET /api/insights/messages — per-message token usage for ONE session.
  ///
  /// The backend keys this on `session_id` (NOT `days`); without a session id it
  /// returns an empty list. Kept for parity / future per-session drill-down.
  Future<List<Map<String, dynamic>>> messages({String? sessionId}) async {
    final resp = await api.get(
      '/api/insights/messages',
      query: sessionId == null ? null : {'session_id': sessionId},
    );
    final data = resp.data;
    final raw = data is Map ? (data['messages'] as List?) : null;
    return parseRows(raw);
  }
}

/// Format a token / count value with thousands separators, e.g. 1234 → "1,234".
/// Accepts any [num]-ish value (num, numeric string, or null → 0).
String formatTokenCount(dynamic value) {
  final n = _asNum(value).round();
  final neg = n < 0;
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i != 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

/// Compact token formatting matching the web panel: 1.2M / 3.4K / 999.
String formatTokensCompact(dynamic value) {
  final n = _asNum(value).abs();
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(1)}K';
  return formatTokenCount(value);
}

/// Format a cost, matching the web panel: 4 decimals under $1, else 2; "—" at 0.
String formatCost(dynamic value) {
  final n = _asNum(value);
  if (n <= 0) return '—';
  return '\$${n.toStringAsFixed(n < 1 ? 4 : 2)}';
}

/// Parse the `models` breakdown list into a clean list of maps. Tolerates a
/// null/absent value, a map keyed by model name (older shape), or the current
/// list-of-objects shape. Always returns rows carrying at least a `model` key.
List<Map<String, dynamic>> parseModelStats(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => (m['model']?.toString().trim().isNotEmpty ?? false) ||
            m.isNotEmpty)
        .map((m) {
          m['model'] = (m['model'] ?? 'unknown').toString();
          return m;
        })
        .toList(growable: false);
  }
  if (value is Map) {
    // {modelName: {sessions, input_tokens, ...}} → flatten to rows.
    return value.entries
        .where((e) => e.value is Map)
        .map((e) => {
              'model': e.key.toString(),
              ...Map<String, dynamic>.from(e.value as Map),
            })
        .toList(growable: false);
  }
  return const [];
}

/// Normalise any list-of-objects payload into `List<Map<String,dynamic>>`.
List<Map<String, dynamic>> parseRows(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: false);
}

/// Best-effort numeric coercion: num, numeric string ("$1,234.5" ok), or 0.
num _asNum(dynamic v) {
  if (v is num) return v;
  if (v is String) {
    final cleaned = v.replaceAll('\$', '').replaceAll(',', '').trim();
    return num.tryParse(cleaned) ?? 0;
  }
  return 0;
}

/// Exposed numeric coercion for the UI (e.g. summing bar values).
num insightsNum(dynamic v) => _asNum(v);
