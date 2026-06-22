import '../services/api_client.dart';

/// Talks to the server's `/api/jarvis-memory/*` endpoints — the jarvis_memory
/// semantic store (the same data the webui "Long-term memory" panel renders).
///
/// Shapes are taken from the REAL backend (webui/api/routes.py
/// `_handle_jarvis_memory_*` + webui/static/jarvis_memory.js), and parsing is
/// deliberately defensive: every endpoint can fail-soft to
/// `{available:false, error:...}` when the store isn't initialized, so callers
/// must tolerate missing/None fields rather than assuming a key exists.
///
/// Key real-shape facts (do NOT "tidy" these to the obvious names):
///   * search returns `data['entries']` (NOT `results`); each entry's text is
///     in `body` (NOT `text`); `id` is a string.
///   * reflections returns `data['reflections']`; each row is a full sqlite row
///     `{id, ts, kind, title, body, status, dedup_key}` where `id` is an
///     INTEGER.
///   * delete / dismiss both POST `{id: ...}` (the server does
///     `require(body, "id")`); dismiss's id is numeric.
///   * reflections/run POSTs an empty body and returns `{ok, new}`.
class JarvisMemoryApi {
  JarvisMemoryApi(this.api);
  final ApiClient api;

  /// GET /api/jarvis-memory/stats →
  /// `{available, count, namespaces:[{namespace,count}]}` (or
  /// `{available:false, error, count:0, namespaces:[]}` when uninitialized).
  /// Returns the decoded map verbatim (defensively normalized to a Map).
  Future<Map<String, dynamic>> stats() async {
    final resp = await api.get('/api/jarvis-memory/stats');
    return _asMap(resp.data);
  }

  /// GET /api/jarvis-memory/status → the provider/embedder/ollama status, e.g.
  /// `{available, embed_model, embed_dim, extract_model, ollama_running,
  /// ollama_url, count, ...}` (or `{available:false, error}`).
  Future<Map<String, dynamic>> status() async {
    final resp = await api.get('/api/jarvis-memory/status');
    return _asMap(resp.data);
  }

  /// GET /api/jarvis-memory/search?q=… → the matching memory entries. The real
  /// backend keys these under `entries`; we also tolerate `results` / a bare
  /// list for robustness. Each entry looks like
  /// `{id, body, source, created_at, score, namespace, tags}`.
  Future<List<Map<String, dynamic>>> search(String q) async {
    final resp = await api.get(
      '/api/jarvis-memory/search',
      query: {'q': q},
    );
    return parseEntries(resp.data);
  }

  /// GET /api/jarvis-memory/reflections → the "new" proactive insight cards,
  /// `{reflections:[{id, ts, kind, title, body, status, dedup_key}]}`.
  Future<List<Map<String, dynamic>>> reflections() async {
    final resp = await api.get('/api/jarvis-memory/reflections');
    final data = _asMap(resp.data);
    return _asMapList(data['reflections']);
  }

  /// POST /api/jarvis-memory/delete `{id}` — forget one memory entry. Entry ids
  /// are strings.
  Future<void> deleteEntry(String id) async {
    await api.postJson('/api/jarvis-memory/delete', {'id': id});
  }

  /// POST /api/jarvis-memory/reflections/dismiss `{id}` — dismiss one insight.
  /// The server requires `id`; reflection ids are integers, so we coerce a
  /// numeric string to int (mirroring the webui, which sends `Number(id)`).
  /// `reflection_id` is also included for forward-compat, but `id` is the one
  /// the backend reads.
  Future<void> dismissReflection(String id) async {
    final dynamic numId = int.tryParse(id) ?? id;
    await api.postJson(
      '/api/jarvis-memory/reflections/dismiss',
      {'id': numId, 'reflection_id': numId},
    );
  }

  /// POST /api/jarvis-memory/reflections/run `{}` — kick a reflection tick.
  /// Returns `{ok, new}` server-side; we don't surface the body here.
  Future<void> runReflections() async {
    await api.postJson('/api/jarvis-memory/reflections/run', const {});
  }

  // ── pure helpers (unit-tested) ──────────────────────────────────────────

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static List<Map<String, dynamic>> _asMapList(dynamic v) => (v is List ? v : const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: false);

  /// Pulls the namespace list out of a `/stats` payload. Accepts the real shape
  /// `{namespaces:[{namespace,count}]}`, a bare list of those maps, and is safe
  /// on null / missing / wrong types (returns `const []`). Each returned map is
  /// normalized to `{namespace:String, count:int}`.
  static List<Map<String, dynamic>> parseNamespaces(dynamic data) {
    final raw = data is Map ? data['namespaces'] : data;
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = (item['namespace'] ?? item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      out.add({'namespace': name, 'count': asInt(item['count'])});
    }
    return out;
  }

  /// Pulls the search-result entries out of a `/search` payload. Real shape is
  /// `{entries:[...]}`; we also accept `{results:[...]}` and a bare list.
  static List<Map<String, dynamic>> parseEntries(dynamic data) {
    final raw = data is Map
        ? (data['entries'] ?? data['results'])
        : data;
    return _asMapList(raw);
  }

  /// Coerce a JSON number / numeric-string / null into an int (0 on failure).
  /// Public so the page can use it for the stats `count` without re-deriving it.
  static int asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }
}
