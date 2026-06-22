import '../services/api_client.dart';

/// Client for the server's shared code-memory store — the per-project
/// code-knowledge + session-handoff records that Claude / the JarvisCopilot
/// agent write while working in a repo. Mirrors the web "Code memory" panel.
///
/// Endpoint shapes verified against webui/api/routes.py + agent/code_memory.py:
///  - GET  /api/code-memory/stats    → flat {projects, knowledge, sessions,
///                                       by_type, last_activity}. `sessions` is
///                                       what the UI labels "Handoffs".
///  - GET  /api/code-memory/projects → {projects: {slug: {name, root, remote,
///                                       first_seen, last_seen, knowledge_count,
///                                       sessions_count}}} — a MAP keyed by slug.
///  - GET  /api/code-memory          → {slug, kind, entries: [{id, ts,
///                                       entry_type, content}]}. kind ∈
///                                       knowledge|sessions; id is
///                                       `slug::kind::ts::ordinal`.
///  - GET  /api/code-memory/search   → {slug, kind, entries: [{id, slug, kind,
///                                       entry_type, ts, first_line}]} — compact
///                                       rows (no full `content`; carries
///                                       `first_line`).
///  - POST /api/code-memory/update       {id, content, entry_type?}
///  - POST /api/code-memory/delete-entry {id}  (preferred) or {slug, kind, ts}
class CodeMemoryApi {
  CodeMemoryApi(this.api);
  final ApiClient api;

  /// Global counts: {projects, knowledge, sessions, by_type, last_activity}.
  /// Returned flat (no wrapper). Tolerate a bare/empty body.
  Future<Map<String, dynamic>> stats() async {
    final resp = await api.get('/api/code-memory/stats');
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// All projects, normalized to a list each carrying its `slug`.
  Future<List<Map<String, dynamic>>> projects() async {
    final resp = await api.get('/api/code-memory/projects');
    final data = resp.data;
    final raw = data is Map ? data['projects'] : data;
    return parseProjects(raw);
  }

  /// Entries for a project. `kind` ∈ knowledge|sessions ("Handoffs" =
  /// sessions). Each row: {id, ts, entry_type, content}.
  Future<List<Map<String, dynamic>>> entries(String slug,
      {String kind = 'knowledge', int limit = 500}) async {
    final resp = await api.get(
      '/api/code-memory',
      query: {'project': slug, 'kind': kind, 'limit': '$limit'},
    );
    return _entriesOf(resp.data);
  }

  /// Server-side search. Returns COMPACT rows ({id, slug, kind, entry_type, ts,
  /// first_line}) — no full `content`. Callers that need the body fetch it on
  /// open (the row's `id` is stable).
  Future<List<Map<String, dynamic>>> search(String slug, String q,
      {String kind = 'knowledge', int limit = 100}) async {
    final resp = await api.get(
      '/api/code-memory/search',
      query: {'project': slug, 'kind': kind, 'q': q, 'limit': '$limit'},
    );
    return _entriesOf(resp.data);
  }

  /// Full bodies for the given entry ids (used to hydrate compact search rows).
  /// GET /api/code-memory/entries?ids=a,b → {entries: [{id, ..., content}]}.
  Future<List<Map<String, dynamic>>> byIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final resp = await api.get(
      '/api/code-memory/entries',
      query: {'ids': ids.join(',')},
    );
    return _entriesOf(resp.data);
  }

  /// Edit one entry in place by id, preserving its timestamp/position.
  Future<void> update(String id, String content, {String? entryType}) async {
    final body = <String, dynamic>{'id': id, 'content': content};
    if (entryType != null) body['entry_type'] = entryType;
    await api.postJson('/api/code-memory/update', body);
  }

  /// Delete a single entry. Prefer the precise `id` form; fall back to the
  /// (slug, kind, ts) form when no id is available.
  Future<void> deleteEntry({String? id, String? slug, String? kind, dynamic ts}) async {
    final body = id != null
        ? <String, dynamic>{'id': id}
        : <String, dynamic>{'slug': slug, 'kind': kind, 'ts': ts};
    await api.postJson('/api/code-memory/delete-entry', body);
  }

  /// Pull `entries` out of any {entries: [...]} envelope; tolerate a bare list.
  static List<Map<String, dynamic>> _entriesOf(dynamic data) {
    final raw = data is Map ? data['entries'] : data;
    return _asMapList(raw);
  }
}

/// Normalize the projects payload to a `List<Map>` where each map carries its
/// `slug`.
///
/// The server returns a MAP keyed by sanitized slug
/// (`{slug: {name, knowledge_count, sessions_count, last_seen, ...}}`), but we
/// also tolerate a bare list (each item already carrying `slug`) and an empty /
/// null body. Pure — unit-tested.
List<Map<String, dynamic>> parseProjects(dynamic raw) {
  if (raw is Map) {
    final out = <Map<String, dynamic>>[];
    raw.forEach((key, value) {
      final m = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      // The map key is the authoritative slug; never let a stray inner field win.
      m['slug'] = '$key';
      out.add(m);
    });
    return out;
  }
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }
  return const [];
}

List<Map<String, dynamic>> _asMapList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: false);
}
