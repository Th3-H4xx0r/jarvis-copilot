import '../services/api_client.dart';

/// Fetches recent self-improvement / self-learning events (skills auto-created
/// or patched, memory updated, and rejected attempts) from the server's
/// GET /api/self-improvement/recent endpoint, which parses
/// ~/.jarviscopilot/self_improvement.log.
class SelfImprovementApi {
  SelfImprovementApi(this.api);
  final ApiClient api;

  Future<List<Map<String, dynamic>>> recent({int limit = 100}) async {
    final resp = await api.get(
      '/api/self-improvement/recent',
      query: {'limit': '$limit'},
    );
    final data = resp.data;
    // Endpoint returns {entries: [...], total, hint}; tolerate a bare list too.
    final raw = data is Map ? (data['entries'] as List?) : (data as List?);
    return (raw ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }
}
