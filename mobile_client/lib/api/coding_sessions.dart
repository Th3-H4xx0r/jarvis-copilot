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

  /// GET /api/coding/sessions -> the sessions plus the account `usage` block
  /// ({five_hour_pct, weekly_pct, ...}) used by the Live Activity rings.
  /// `usage` is null when the server can't compute it.
  Future<({List<CodingSession> sessions, Map<String, dynamic>? usage})>
      listSessionsWithUsage() async {
    final resp = await api.get('/api/coding/sessions');
    final data = resp.data as Map?;
    final raw = (data?['sessions'] as List?) ?? const [];
    final sessions = raw
        .whereType<Map>()
        .map((m) => CodingSession.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    final u = data?['usage'];
    return (
      sessions: sessions,
      usage: u is Map ? Map<String, dynamic>.from(u) : null,
    );
  }

  /// GET /api/coding/usage -> `{usage: {five_hour_pct, weekly_pct, ...}|null}`.
  Future<Map<String, dynamic>?> getUsage() async {
    final resp = await api.get('/api/coding/usage');
    final u = (resp.data as Map?)?['usage'];
    return u is Map ? Map<String, dynamic>.from(u) : null;
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

  /// GET /api/coding/projects?expand=sessions ->
  /// `{ projects: [{..., sessions:[...]}], ungrouped: [...] }`.
  ///
  /// Each project carries its nested `sessions`; `ungrouped` holds sessions with
  /// no project (legacy rows + discovered sessions). Returns both so the page
  /// can render the Projects→Sessions tree (parity with the WebUI sidebar).
  Future<CodingProjectsView> listProjectsExpanded() async {
    final resp = await api.get(
      '/api/coding/projects',
      query: const {'expand': 'sessions'},
    );
    final data = resp.data as Map?;
    final rawProjects = (data?['projects'] as List?) ?? const [];
    final rawUngrouped = (data?['ungrouped'] as List?) ?? const [];
    final projects = rawProjects
        .whereType<Map>()
        .map((m) => CodingProject.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    final ungrouped = rawUngrouped
        .whereType<Map>()
        .map((m) => CodingSession.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    return CodingProjectsView(projects: projects, ungrouped: ungrouped);
  }

  /// POST /api/coding/projects {name, repo_path} -> `{ ok, project_id }`.
  Future<String?> createProject({
    required String name,
    required String repoPath,
    String? defaultBranch,
  }) async {
    final resp = await api.postJson('/api/coding/projects', {
      'name': name,
      'repo_path': repoPath,
      if (defaultBranch != null && defaultBranch.isNotEmpty)
        'default_branch': defaultBranch,
    });
    final body = resp.data as Map?;
    return _str(body?['project_id']);
  }

  /// POST /api/coding/project/$id {name?, default_branch?, sync_enabled?,
  /// sync_desktop_path?, ignore_rules?, device_id?} — rename / set sync.
  Future<void> updateProject(
    String id, {
    String? name,
    String? defaultBranch,
    bool? syncEnabled,
    String? syncDesktopPath,
    String? ignoreRules,
    String? deviceId,
  }) async {
    await api.postJson('/api/coding/project/$id', {
      if (name != null) 'name': name,
      if (defaultBranch != null) 'default_branch': defaultBranch,
      if (syncEnabled != null) 'sync_enabled': syncEnabled,
      if (syncDesktopPath != null) 'sync_desktop_path': syncDesktopPath,
      if (ignoreRules != null) 'ignore_rules': ignoreRules,
      if (deviceId != null) 'device_id': deviceId,
    });
  }

  /// DELETE /api/coding/project/$id?delete_sessions=0|1 — `delete=true` cascades
  /// (stop + remove its sessions); otherwise its sessions become Ungrouped.
  Future<void> deleteProject(String id, {bool cascade = false}) async {
    await api.deleteJson(
      '/api/coding/project/$id?delete_sessions=${cascade ? 1 : 0}',
    );
  }

  /// POST /api/coding/project/$id/session {cwd?, title?, prompt?, model?, host?,
  /// skip_permissions?, sync?} -> `{ session }`. cwd defaults server-side to the
  /// project's repo_path when omitted.
  Future<CodingSession> launchInProject(
    String projectId, {
    String? cwd,
    String? title,
    String? prompt,
    String? model,
    String? host,
    bool skipPermissions = false,
    CodingSync? sync,
  }) async {
    final resp = await api.postJson('/api/coding/project/$projectId/session', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (title != null && title.isNotEmpty) 'title': title,
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
      if (model != null && model.isNotEmpty) 'model': model,
      if (host != null && host.isNotEmpty) 'host': host,
      if (skipPermissions) 'skip_permissions': true,
      if (sync != null && sync.enabled) 'sync': sync.toJson(),
    });
    final body = resp.data as Map?;
    final session = (body?['session'] as Map?) ?? body ?? const {};
    return CodingSession.fromJson(Map<String, dynamic>.from(session));
  }

  /// POST /api/coding/session/$id/resume -> `{ ok, session? }`. Relaunch a
  /// discovered-transcript (past) session on its device. The resumed session
  /// may keep the same id or be reported under a new one.
  Future<CodingSession?> resume(String id) async {
    final resp = await api.postJson('/api/coding/session/$id/resume', const {});
    final body = resp.data as Map?;
    final session = body?['session'] as Map?;
    if (session == null) return null;
    return CodingSession.fromJson(Map<String, dynamic>.from(session));
  }

  /// POST /api/coding/discover/refresh — ask the paired device to re-scan its
  /// live tmux + transcript sessions and re-report. Discovery is async over the
  /// bridge, so callers should refresh the list again shortly after.
  Future<void> discoverRefresh() async {
    await api.postJson('/api/coding/discover/refresh', const {});
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

/// The expanded `/projects?expand=sessions` payload: projects (each with their
/// nested sessions) plus the synthetic Ungrouped bucket of project-less
/// sessions (legacy rows + discovered sessions).
class CodingProjectsView {
  const CodingProjectsView({
    this.projects = const [],
    this.ungrouped = const [],
  });

  final List<CodingProject> projects;
  final List<CodingSession> ungrouped;
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}
