/// Data models for the native Coding Sessions tab.
///
/// These mirror the server's `coding_sessions` control plane (see
/// `agent/coding_session_db.py` and `agent/coding_subagent_tracker.py`):
/// a session is a tmux-backed Claude Code run, optionally spawning Task
/// subagents whose progress is parsed from the transcript.
library;

/// A coding session row (`GET /api/coding/sessions`,
/// `/api/coding/session/$id`).
class CodingSession {
  CodingSession({
    required this.id,
    this.title,
    this.status = 'starting',
    this.host,
    this.cwd,
    this.branch,
    this.claudeSessionId,
    this.source,
    this.createdAt,
  });

  final String id;
  final String? title;
  final String status; // starting | running | idle | stopped | error
  final String? host;
  final String? cwd;
  final String? branch;
  final String? claudeSessionId;
  final String? source;
  final double? createdAt; // epoch seconds (REAL)

  factory CodingSession.fromJson(Map<String, dynamic> j) {
    return CodingSession(
      id: (j['id'] ?? '').toString(),
      title: _str(j['title']),
      status: (j['status'] ?? 'starting').toString(),
      host: _str(j['host']),
      cwd: _str(j['cwd']),
      branch: _str(j['branch']),
      claudeSessionId: _str(j['claude_session_id']),
      source: _str(j['source']),
      createdAt: _asDouble(j['created_at']),
    );
  }

  String get displayTitle {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return t;
    final dir = (cwd ?? '').trim();
    if (dir.isNotEmpty) return dir.split('/').last;
    return 'Session ${id.isEmpty ? '' : id.substring(0, id.length.clamp(0, 8))}';
  }

  bool get isLive => status == 'running' || status == 'starting' || status == 'idle';
}

/// A registered coding project (`GET /api/coding/projects`).
class CodingProject {
  CodingProject({
    required this.id,
    required this.name,
    this.repoPath,
    this.host,
    this.defaultBranch,
  });

  final String id;
  final String name;
  final String? repoPath;
  final String? host;
  final String? defaultBranch;

  factory CodingProject.fromJson(Map<String, dynamic> j) {
    return CodingProject(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      repoPath: _str(j['repo_path']),
      host: _str(j['host']),
      defaultBranch: _str(j['default_branch']),
    );
  }
}

/// A Task subagent spawned by a session (parsed from the transcript).
class CodingSubagent {
  CodingSubagent({
    this.subType = '',
    this.description = '',
    this.status = 'running',
  });

  final String subType; // e.g. "explorer"
  final String description;
  final String status; // running | completed

  factory CodingSubagent.fromJson(Map<String, dynamic> j) {
    return CodingSubagent(
      subType: (j['sub_type'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      status: (j['status'] ?? 'running').toString(),
    );
  }

  bool get isCompleted => status == 'completed';

  String get displayLabel {
    final t = subType.trim();
    return t.isEmpty ? 'subagent' : t;
  }
}

/// The `/api/coding/session/$id` payload: `{ session, subagents }`.
class CodingSessionDetail {
  CodingSessionDetail({required this.session, this.subagents = const []});

  final CodingSession session;
  final List<CodingSubagent> subagents;

  factory CodingSessionDetail.fromJson(Map<String, dynamic> j) {
    final s = (j['session'] as Map?) ?? j;
    final rawSubs = (j['subagents'] as List?) ?? const [];
    return CodingSessionDetail(
      session: CodingSession.fromJson(Map<String, dynamic>.from(s)),
      subagents: rawSubs
          .whereType<Map>()
          .map((m) => CodingSubagent.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
    );
  }
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

double? _asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
