import '../services/api_client.dart';

/// /api/sessions wrapper. Mirrors the webui's session list shape so the
/// native Chat page can render the same list as the desktop sidebar.
class SessionsApi {
  SessionsApi(this.api);
  final ApiClient api;

  Future<List<Map<String, dynamic>>> list({bool allProfiles = false}) async {
    final resp = await api.get('/api/sessions',
        query: allProfiles ? {'all_profiles': '1'} : null);
    final data = resp.data as Map;
    final raw = (data['sessions'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  /// Persist an on-device turn (handled locally, no server agent) into the
  /// session transcript so it shows on the web + other devices. Best-effort.
  Future<void> appendLocalTurn(
    String sessionId, {
    required String user,
    required String assistant,
  }) async {
    if (assistant.trim().isEmpty && user.trim().isEmpty) return;
    try {
      await api.postJson('/api/session/append', {
        'session_id': sessionId,
        'user': user,
        'assistant': assistant,
        'on_device': true,
      });
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> get(String sessionId) async {
    final resp = await api.get('/api/session',
        query: {'session_id': sessionId, 'messages': '1', 'resolve_model': '0'});
    final body = resp.data as Map?;
    if (body == null) return null;
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> create({String? title, String? profile}) async {
    final resp = await api.postJson('/api/session/new', {
      if (title != null) 'title': title,
      if (profile != null) 'profile': profile,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Future<void> pin(String sessionId, bool pinned) async {
    await api.postJson('/api/session/pin', {
      'session_id': sessionId,
      'pinned': pinned,
    });
  }

  Future<void> rename(String sessionId, String title) async {
    await api.postJson('/api/session/rename', {
      'session_id': sessionId,
      'title': title,
    });
  }
}
