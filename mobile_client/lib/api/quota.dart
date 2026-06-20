import '../services/api_client.dart';

/// One usage window within a provider's quota (e.g. "Current session",
/// "Current week"). [usedPercent] is 0..100, or null when the server couldn't
/// compute it (the UI then shows "—" with an empty bar instead of a fake value).
class QuotaWindow {
  const QuotaWindow({
    required this.label,
    this.usedPercent,
    this.remainingPercent,
    this.resetAt,
    this.detail,
  });

  final String label;
  final double? usedPercent;
  final double? remainingPercent;
  final DateTime? resetAt;
  final String? detail;

  static double? parseNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static DateTime? parseDate(dynamic v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  static String? _trimmed(dynamic v) {
    final s = (v as String?)?.trim();
    return (s != null && s.isNotEmpty) ? s : null;
  }

  factory QuotaWindow.fromJson(Map<String, dynamic> j) => QuotaWindow(
        label: (j['label'] ?? '').toString(),
        usedPercent: parseNum(j['used_percent']),
        remainingPercent: parseNum(j['remaining_percent']),
        resetAt: parseDate(j['reset_at']),
        detail: _trimmed(j['detail']),
      );
}

/// A configured quota-capable provider (Claude Code, Codex, …) and its windows —
/// the same usage data the web Providers panel and the Dynamic Island show.
class QuotaProvider {
  const QuotaProvider({
    required this.provider,
    required this.displayName,
    required this.windows,
    this.plan,
    this.details = const [],
    this.fetchedAt,
  });

  final String provider;
  final String displayName;
  final List<QuotaWindow> windows;
  final String? plan;
  final List<String> details;
  final DateTime? fetchedAt;

  factory QuotaProvider.fromJson(Map<String, dynamic> j) => QuotaProvider(
        provider: (j['provider'] ?? '').toString(),
        displayName: (j['display_name'] ?? j['provider'] ?? '').toString(),
        plan: QuotaWindow._trimmed(j['plan']),
        windows: ((j['windows'] as List?) ?? const [])
            .whereType<Map>()
            .map((w) => QuotaWindow.fromJson(Map<String, dynamic>.from(w)))
            .where((w) => w.label.isNotEmpty)
            .toList(growable: false),
        details: ((j['details'] as List?) ?? const [])
            .map((d) => d.toString())
            .where((d) => d.trim().isNotEmpty)
            .toList(growable: false),
        fetchedAt: QuotaWindow.parseDate(j['fetched_at']),
      );
}

/// REST wrapper for provider quota/usage (`/api/provider/quota/all`).
///
/// One call returns every configured quota-capable provider (Claude Code,
/// Codex, plus Anthropic / OpenRouter when configured), each with its limit
/// windows carrying a `used_percent` for the progress bars.
class QuotaApi {
  QuotaApi(this.api);
  final ApiClient api;

  Future<List<QuotaProvider>> getAll({bool refresh = false}) async {
    final resp = await api.get(
      '/api/provider/quota/all',
      query: refresh ? const {'refresh': '1'} : null,
    );
    final data = resp.data as Map?;
    final raw = (data?['providers'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => QuotaProvider.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }
}
