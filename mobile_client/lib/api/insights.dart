import '../services/api_client.dart';

/// REST wrapper for the WebUI usage analytics (`/api/insights`) and the
/// companion observability endpoints that the web "Usage Analytics" Insights
/// panel renders alongside it: host system health (`/api/system/health`) and
/// LLM Wiki status (`/api/wiki/status`), plus per-message token usage for one
/// session (`/api/insights/messages`).
///
/// The overview backend (`_handle_insights` in webui/api/routes.py) returns,
/// for a `days` window (1..365):
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

  /// GET /api/system/health → coarse host CPU/RAM/disk usage.
  ///
  /// Shape (from `build_system_health_payload`):
  ///   { status, available, checked_at,
  ///     cpu:   {percent} | null,
  ///     memory:{used_bytes, total_bytes, percent} | null,
  ///     disk:  {used_bytes, total_bytes, percent} | null,
  ///     errors: [...] }
  /// Returns `{}` on any failure so the caller can simply hide the section.
  Future<Map<String, dynamic>> systemHealth() async {
    try {
      final resp = await api.get('/api/system/health');
      final data = resp.data;
      return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// GET /api/wiki/status → LLM Wiki knowledge-base observability metadata.
  ///
  /// Shape (from `_build_llm_wiki_status`):
  ///   { available, enabled, status, entry_count, page_count,
  ///     raw_source_count, last_updated, last_writer, path_configured,
  ///     path_source, toggle_available, toggle_reason, docs_url, [error] }
  /// Returns an error-shaped map on failure (never throws) so the section can
  /// render an "Unavailable" / "Error" state gracefully.
  Future<Map<String, dynamic>> wikiStatus() async {
    try {
      final resp = await api.get('/api/wiki/status');
      final data = resp.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return <String, dynamic>{'status': 'error'};
    } catch (e) {
      return <String, dynamic>{'status': 'error', 'error': e.toString()};
    }
  }

  /// GET /api/insights/messages?session_id=… — per-message token usage for ONE
  /// session. The backend keys this on `session_id` (NOT `days`); without a
  /// session id it returns an empty list.
  ///
  /// Each record: { turn, timestamp, model, provider, input_tokens,
  /// output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
  /// latency_s, composition: {sections: {key: tokens, ...}} }, newest first.
  Future<List<Map<String, dynamic>>> messages({String? sessionId}) async {
    if (sessionId == null || sessionId.isEmpty) return const [];
    try {
      final resp = await api.get(
        '/api/insights/messages',
        query: {'session_id': sessionId},
      );
      final data = resp.data;
      final raw = data is Map ? (data['messages'] as List?) : null;
      return parseRows(raw);
    } catch (_) {
      return const [];
    }
  }

  /// Resolve the active chat session id the way the Todos screen does: the
  /// mobile app has no app-level "active session" singleton, so we mirror what
  /// the user sees as their open chat — the most-recently-updated session.
  /// Returns null when there are no sessions (so the Messages section hides).
  Future<String?> activeSessionId() async {
    try {
      final resp = await api.get('/api/sessions');
      final data = resp.data;
      final s = data is Map ? data['sessions'] : data;
      final raw = s is List ? s : const [];
      final rows = raw.whereType<Map>().toList();
      if (rows.isEmpty) return null;
      int updatedOf(Map m) =>
          (_asNum(m['updated_at'] ?? m['last_message_at'])).round();
      rows.sort((a, b) => updatedOf(b).compareTo(updatedOf(a)));
      for (final m in rows) {
        final id = (m['session_id'] ?? m['id'] ?? '').toString();
        if (id.isNotEmpty) return id;
      }
      return null;
    } catch (_) {
      return null;
    }
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

/// Human-readable bytes (B/KB/MB/GB/TB) — mirrors the web's
/// `_formatSystemHealthBytes` rounding (0 decimals at >=10 or for bytes).
String formatBytes(dynamic value) {
  var n = _asNum(value).toDouble();
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var idx = 0;
  while (n >= 1024 && idx < units.length - 1) {
    n /= 1024;
    idx++;
  }
  final decimals = (n >= 10 || idx == 0) ? 0 : 1;
  return '${n.toStringAsFixed(decimals)} ${units[idx]}';
}

/// A system-health metric's percent as 0..100 (clamped), or null when the
/// metric block is absent. Tolerates the cpu shape ({percent}) and the
/// memory/disk shape ({used_bytes,total_bytes,percent}).
double? systemHealthPercent(dynamic metric) {
  if (metric is! Map) return null;
  final p = metric['percent'];
  if (p == null) return null;
  return _asNum(p).clamp(0, 100).toDouble();
}

/// The "used / total" subtitle for memory/disk metrics, or '' when absent
/// (CPU has no byte counts).
String systemHealthBytesLabel(dynamic metric) {
  if (metric is! Map) return '';
  final used = metric['used_bytes'];
  final total = metric['total_bytes'];
  if (used == null || total == null) return '';
  if (_asNum(total) <= 0) return '';
  return '${formatBytes(used)} / ${formatBytes(total)}';
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

/// Pull the per-message input-composition map (`composition.sections`) out of a
/// message record as `{sectionKey: tokens}`, dropping non-positive entries.
/// Returns `{}` when no composition is present.
Map<String, num> messageComposition(Map<String, dynamic> message) {
  final comp = message['composition'];
  final sections = comp is Map ? comp['sections'] : null;
  if (sections is! Map) return const {};
  final out = <String, num>{};
  sections.forEach((k, v) {
    final n = _asNum(v);
    if (n > 0) out[k.toString()] = n;
  });
  return out;
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
