import '../coding/coding_models.dart';
import '../services/api_client.dart';

/// REST wrapper for the Coding Sessions control plane (`/api/coding/*`).
///
/// Mirrors the server's `coding_sessions` toolset: launch/list/inspect/drive
/// tmux-backed Claude Code sessions. Named [CodingSessionsApi] (NOT
/// `SessionsApi` — that's taken by the chat sessions list).
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

  /// POST /api/coding/launch -> `{ session: {...} }`
  Future<CodingSession> launch({
    String? cwd,
    String? repoPath,
    bool worktree = false,
    String? title,
    String? prompt,
    String? model,
  }) async {
    final resp = await api.postJson('/api/coding/launch', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (repoPath != null && repoPath.isNotEmpty) 'repo_path': repoPath,
      if (worktree) 'worktree': true,
      if (title != null && title.isNotEmpty) 'title': title,
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
      if (model != null && model.isNotEmpty) 'model': model,
    });
    final body = resp.data as Map?;
    final session = (body?['session'] as Map?) ?? body ?? const {};
    return CodingSession.fromJson(Map<String, dynamic>.from(session));
  }

  /// GET /api/coding/session/$id -> `{ session, subagents }`
  Future<CodingSessionDetail> get(String id) async {
    final resp = await api.get('/api/coding/session/$id');
    final body = (resp.data as Map?) ?? const {};
    return CodingSessionDetail.fromJson(Map<String, dynamic>.from(body));
  }

  /// POST /api/coding/session/$id/message
  Future<void> sendMessage(String id, String text) async {
    await api.postJson('/api/coding/session/$id/message', {'text': text});
  }

  /// POST /api/coding/session/$id/stop
  Future<void> stop(String id) async {
    await api.postJson('/api/coding/session/$id/stop', const {});
  }
}
