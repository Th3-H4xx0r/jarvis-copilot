import '../services/api_client.dart';

/// Talks to the WebUI profile endpoints — the same set the web Profiles panel
/// uses. There is NO profile-edit endpoint on the server, so this exposes only
/// list / active / switch / create / delete.
///
/// Shapes (from webui/api/routes.py + api/profiles.py):
///   GET  /api/profiles        → {profiles: [ {name, path, model, provider, ...} ], active: name}
///   GET  /api/profile/active  → {name, path}
///   POST /api/profile/switch  → {profiles, active, default_model, ...}  (active = new profile)
///   POST /api/profile/create  → {ok, profile}
///   POST /api/profile/delete  → { ... }
class ProfilesApi {
  ProfilesApi(this.api);
  final ApiClient api;

  /// All profiles plus the active profile name: `{profiles: [...], active: name}`.
  Future<Map<String, dynamic>> list() async {
    final resp = await api.get('/api/profiles');
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// The currently active profile: `{name, path}`.
  Future<Map<String, dynamic>> active() async {
    final resp = await api.get('/api/profile/active');
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// Switch the active profile. Returns the raw server response, which reports
  /// the new active profile via its `active` key — callers should verify it
  /// matches [name] rather than assuming success.
  Future<Map<String, dynamic>> switchTo(String name) async {
    final resp = await api.postJson('/api/profile/switch', {'name': name});
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// Create a profile. [body] may contain: name (required), clone_from,
  /// clone_config (bool), base_url, api_key, default_model, model_provider.
  /// Only non-empty keys should be passed in.
  Future<void> create(Map<String, dynamic> body) async {
    await api.postJson('/api/profile/create', body);
  }

  /// Delete a named profile.
  Future<void> delete(String name) async {
    await api.postJson('/api/profile/delete', {'name': name});
  }
}

// ── Pure helpers (no I/O) so the page stays thin and the parsing is testable ──

/// Parse the `{profiles: [...], active: ...}` map (or a bare list, defensively)
/// into a list of profile maps. Tolerates nulls, non-list `profiles`, and
/// non-map entries — always returns a clean `List<Map<String, dynamic>>`.
List<Map<String, dynamic>> parseProfiles(dynamic data) {
  final raw = data is Map ? data['profiles'] : data;
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: false);
}

/// Extract the active profile name from a `{active: ...}` map. Returns '' when
/// absent/blank so the UI can treat "no active" uniformly.
String activeName(dynamic data) {
  if (data is Map) {
    final a = data['active'] ?? data['name'];
    if (a != null) return a.toString();
  }
  return '';
}
