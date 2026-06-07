import '../coding/coding_models.dart';
import '../services/api_client.dart';

/// REST wrapper for the Coding Sessions control plane (`/api/coding/*`)
/// plus the shared live-terminal machinery (`/api/terminal/*`).
///
/// Mirrors the server's `coding_sessions` toolset: launch/list/inspect/drive
/// tmux-backed Claude Code sessions, plus restart/delete/settings and a live
/// terminal attached over SSE. Named [CodingSessionsApi] (NOT `SessionsApi` —
/// that's taken by the chat sessions list).
class CodingSessionsApi {
  CodingSessionsApi(this.api);
  final ApiClient api;

  /// GET /api/coding/sessions -> `{ sessions: [...] }`
  Future<List<CodingSession>> listSessions() async {
    final resp = await api.get('/api/coding/sessions');
    final data = resp.data as Map?;
    final raw = (data?['sessions'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => CodingSession.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// GET /api/coding/projects -> `{ projects: [...] }`
  Future<List<CodingProject>> listProjects() async {
    final resp = await api.get('/api/coding/projects');
    final data = resp.data as Map?;
    final raw = (data?['projects'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => CodingProject.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// GET /api/devices -> `{ devices: [...] }`.
  ///
  /// Paired/registered devices for the sync "Device" dropdown (parity with the
  /// WebUI). Filtered to sync-capable DESKTOP devices only — a device is kept
  /// when `kind == 'desktop'` OR `bridge_connected == true` (a live jc-client
  /// agent). Web/mobile pairings can't sync, so they're dropped. Offline
  /// desktops are still returned but flagged. Tolerates the body being a bare
  /// list or missing the `devices` key.
  Future<List<CodingDevice>> listDevices() async {
    final resp = await api.get('/api/devices');
    final data = resp.data;
    final raw = data is Map
        ? (data['devices'] as List?) ?? const []
        : (data is List ? data : const []);
    return raw
        .whereType<Map>()
        .map((m) => CodingDevice.fromJson(Map<String, dynamic>.from(m)))
        .where((d) => d.id.isNotEmpty && d.desktopCapable)
        .toList(growable: false);
  }

  /// POST /api/coding/launch -> `{ session: {...} }`.
  ///
  /// Sends `cwd` + `repo_path` (so either server-side naming works), plus the
  /// host/skip-permissions/sync parity fields from the WebUI launch form.
  Future<CodingSession> launch({
    String? cwd,
    String? repoPath,
    bool worktree = false,
    String? title,
    String? prompt,
    String? model,
    String host = 'server',
    bool skipPermissions = false,
    CodingSync? sync,
  }) async {
    final resp = await api.postJson('/api/coding/launch', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (repoPath != null && repoPath.isNotEmpty) 'repo_path': repoPath,
      if (worktree) 'worktree': true,
      if (title != null && title.isNotEmpty) 'title': title,
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
      if (model != null && model.isNotEmpty) 'model': model,
      'host': host,
      if (skipPermissions) 'skip_permissions': true,
      if (sync != null && sync.enabled) 'sync': sync.toJson(),
    });
    final body = resp.data as Map?;
    final session = (body?['session'] as Map?) ?? body ?? const {};
    return CodingSession.fromJson(Map<String, dynamic>.from(session));
  }

  /// GET /api/coding/session/$id -> `{ session, ... }`
  Future<CodingSessionDetail> get(String id) async {
    final resp = await api.get('/api/coding/session/$id');
    final body = (resp.data as Map?) ?? const {};
    return CodingSessionDetail.fromJson(Map<String, dynamic>.from(body));
  }

  /// GET /api/coding/session/$id/sync — live cross-device sync status:
  /// `{enabled, device, device_online, status, direction, total, done,
  /// last_sync_at, error}`.
  Future<CodingSyncStatus> syncStatus(String id) async {
    final resp = await api.get('/api/coding/session/$id/sync');
    final body = (resp.data as Map?) ?? const {};
    return CodingSyncStatus.fromJson(Map<String, dynamic>.from(body));
  }

  /// POST /api/coding/session/$id/sync/refresh — kick a fresh sync pass.
  Future<void> refreshSync(String id) async {
    await api.postJson('/api/coding/session/$id/sync/refresh', const {});
  }

  /// POST /api/coding/session/$id/message
  Future<void> sendMessage(String id, String text) async {
    await api.postJson('/api/coding/session/$id/message', {'text': text});
  }

  /// POST /api/coding/session/$id/stop
  Future<void> stop(String id) async {
    await api.postJson('/api/coding/session/$id/stop', const {});
  }

  /// POST /api/coding/session/$id/restart -> `{ session: {...} }`
  Future<CodingSession?> restart(String id) async {
    final resp = await api.postJson('/api/coding/session/$id/restart', const {});
    final body = resp.data as Map?;
    final session = (body?['session'] as Map?);
    if (session == null) return null;
    return CodingSession.fromJson(Map<String, dynamic>.from(session));
  }

  /// POST /api/coding/session/$id/delete — stop + permanently remove.
  Future<void> delete(String id) async {
    await api.postJson('/api/coding/session/$id/delete', const {});
  }

  /// POST /api/coding/session/$id/settings — partial update of
  /// `{skip_permissions?, sync?, cwd?}`. This endpoint is being added
  /// server-side; callers should tolerate a 404 (treat as "not supported yet").
  Future<void> updateSettings(
    String id, {
    bool? skipPermissions,
    CodingSync? sync,
    String? cwd,
  }) async {
    await api.postJson('/api/coding/session/$id/settings', {
      if (skipPermissions != null) 'skip_permissions': skipPermissions,
      if (sync != null) 'sync': sync.toJson(),
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
  }

  // ── Live terminal (shared /api/terminal/* machinery, keyed by session id) ──

  /// POST /api/coding/session/$id/terminal/start — attach a server-side PTY
  /// to the session's tmux so it can be streamed over SSE.
  Future<void> terminalStart(String id, {int rows = 24, int cols = 80}) async {
    await api.postJson('/api/coding/session/$id/terminal/start', {
      'rows': rows,
      'cols': cols,
    });
  }

  /// SSE GET /api/terminal/output?session_id=$id — yields decoded events.
  /// Named events: `output` (`{text}`), `terminal_closed`, `terminal_error`.
  Stream<Map<String, dynamic>> terminalOutput(String id) {
    return api.streamSse('/api/terminal/output', query: {'session_id': id});
  }

  /// POST /api/terminal/input {session_id, data} — send keystrokes.
  Future<void> terminalInput(String id, String data) async {
    await api.postJson('/api/terminal/input', {'session_id': id, 'data': data});
  }

  /// POST /api/terminal/resize {session_id, rows, cols}.
  Future<void> terminalResize(String id, {required int rows, required int cols}) async {
    await api.postJson('/api/terminal/resize', {
      'session_id': id,
      'rows': rows,
      'cols': cols,
    });
  }

  /// POST /api/terminal/close {session_id} — detach the PTY (does NOT kill
  /// the tmux session / claude).
  Future<void> terminalClose(String id) async {
    await api.postJson('/api/terminal/close', {'session_id': id});
  }
}
