/// Data models for the native Coding Sessions tab.
///
/// These mirror the server's `coding_sessions` control plane (see
/// `agent/coding_session_db.py`): a session is a tmux-backed Claude Code
/// run on the server or a paired desktop, optionally synced with another
/// device.
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
    this.model,
    this.skipPermissions = false,
    this.sync,
    this.createdAt,
    this.projectId,
    this.external = false,
    this.deviceId,
    this.tmuxName,
    this.lastActivityAt,
    this.activityState,
  });

  final String id;
  final String? title;
  final String status; // starting | running | idle | stopped | error
  final String? host; // server | desktop
  final String? cwd;
  final String? branch;
  final String? claudeSessionId;
  final String? source; // chat | manual | discovered-tmux | discovered-transcript
  final String? model;
  final bool skipPermissions;
  final CodingSync? sync;
  final double? createdAt; // epoch seconds (REAL)

  // ── Projects / discovery (Phase 4) ──
  /// The owning project's id (`null` ⇒ Ungrouped).
  final String? projectId;

  /// True for device-discovered sessions (a live tmux or a past transcript
  /// surfaced from a paired desktop). Drives the "discovered/live" badge.
  final bool external;

  /// The device that owns a discovered session (used by resume, informational).
  final String? deviceId;

  /// The tmux session name backing a live session (informational).
  final String? tmuxName;

  /// Last activity timestamp — preferred sort key over [createdAt]. May be an
  /// epoch number or an ISO/string; kept as a string for robust comparison.
  final String? lastActivityAt;

  /// Live activity sub-state of a running session: `working | waiting | idle`
  /// (server-detected from the tmux pane). `null` = unknown / not running.
  final String? activityState;

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
      model: _str(j['model']),
      skipPermissions: _asBool(j['skip_permissions']),
      sync: CodingSync.tryFromJson(j['sync']),
      createdAt: _asDouble(j['created_at']),
      projectId: _str(j['project_id']),
      external: _asBool(j['external']),
      deviceId: _str(j['device_id']),
      tmuxName: _str(j['tmux_name']),
      lastActivityAt: _str(j['last_activity_at']),
      activityState: _str(j['activity_state']),
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

  /// Normalised status bucket, mirroring the WebUI's `_cdgStatusClass`.
  /// running | done | error | stopped | idle.
  String get statusClass {
    switch (status.toLowerCase()) {
      case 'running':
      case 'active':
      case 'busy':
        return 'running';
      case 'done':
      case 'completed':
      case 'finished':
        return 'done';
      case 'error':
      case 'failed':
        return 'error';
      case 'stopped':
      case 'cancelled':
      case 'canceled':
        return 'stopped';
      default:
        return 'idle';
    }
  }

  /// Display state for the dot/label: a live (running) session refines into
  /// `working | waiting | idle` via [activityState] (Scheme 4); other lifecycle
  /// states pass through. Mirrors the WebUI's `_cdgDisplayState`.
  String get liveState {
    if (isTranscriptIdle) return 'history';
    // The server detects activity_state for any LIVE session (running, starting,
    // or idle lifecycle), so refine all of them — not just 'running' — otherwise
    // a session whose lifecycle is idle/starting but whose pane is a permission
    // prompt would wrongly show grey instead of the purple "waiting" signal.
    if (isLive) {
      switch ((activityState ?? '').toLowerCase()) {
        case 'waiting':
          return 'waiting';
        case 'working':
          return 'working';
        case 'idle':
          return 'idle';
        default:
          // No detected sub-state yet: a running session is presumably working;
          // a starting/idle lifecycle with no pane reading stays idle.
          return statusClass == 'running' ? 'working' : 'idle';
      }
    }
    return statusClass;
  }

  /// A transcript-only (`discovered-transcript`) session that isn't currently
  /// running — a PAST conversation with no live tmux. It can be **resumed** on
  /// its device. Mirrors the WebUI's `_codingIsTranscriptIdle`.
  bool get isTranscriptIdle =>
      source == 'discovered-transcript' && statusClass != 'running';

  /// A live (tmux) session that ENDED — claude quit / its tmux is gone, so the
  /// server reconciled it to stopped (a discovered Mac session) or stopped/error
  /// (a server-launched session whose tmux died, e.g. you ctrl-C'd it). It has no
  /// live terminal to attach; offer the recovery actions (relaunch on device /
  /// resume on server / reopen terminal) instead. Mirrors `_codingIsEnded`.
  bool get isEnded {
    final src = source ?? '';
    if (src == 'discovered-transcript') return false; // that's transcript-idle
    final cls = statusClass;
    if (src.startsWith('discovered') && cls == 'stopped') return true;
    final h = (host ?? '').isEmpty ? 'server' : host!;
    if (h == 'server' && (cls == 'stopped' || cls == 'error')) return true;
    return false;
  }

  /// Epoch SECONDS used to sort sessions newest-first. Prefers `last_activity_at`,
  /// falls back to `created_at`. Handles numeric epochs (seconds OR milliseconds)
  /// and ISO strings; 0 when unknown. (A plain string compare mis-ordered these.)
  double get recencyTs {
    final raw = (lastActivityAt != null && lastActivityAt!.isNotEmpty)
        ? lastActivityAt!
        : (createdAt?.toString() ?? '');
    if (raw.isEmpty) return 0;
    final n = double.tryParse(raw);
    if (n != null) return n > 1e12 ? n / 1000 : n; // normalise ms → s
    final d = DateTime.tryParse(raw);
    return d == null ? 0 : d.millisecondsSinceEpoch / 1000;
  }

  /// Resolve the host/source badge shown on the session row. Priority:
  /// history (idle transcript) > discovered/live (external) > desktop > server.
  /// Mirrors the WebUI badge logic in `_codingSessionRowHtml`.
  ({String kind, String label}) get badge {
    if (isTranscriptIdle) return (kind: 'history', label: 'history');
    if (external) {
      final live = source == 'discovered-transcript' && statusClass == 'running';
      return (kind: 'discovered', label: live ? 'live' : 'discovered');
    }
    if ((host ?? '').toLowerCase() == 'desktop') {
      return (kind: 'desktop', label: 'desktop');
    }
    return (kind: 'server', label: 'server');
  }
}

/// Cross-device file sync config for a session
/// (`sync: {enabled, device, remote_path}`).
class CodingSync {
  const CodingSync({
    this.enabled = false,
    this.device,
    this.remotePath,
  });

  final bool enabled;
  final String? device;
  final String? remotePath;

  /// Parse a `sync` blob that may be a Map, or null/absent.
  static CodingSync? tryFromJson(Object? v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    return CodingSync(
      enabled: _asBool(m['enabled']),
      device: _str(m['device']),
      remotePath: _str(m['remote_path']),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        if ((device ?? '').isNotEmpty) 'device': device,
        if ((remotePath ?? '').isNotEmpty) 'remote_path': remotePath,
      };
}

/// A registered coding project with its nested sessions
/// (`GET /api/coding/projects?expand=sessions`).
///
/// `device_id`/`sync_*`/`ignore_rules` mirror the project's cross-device sync
/// config (parity with the WebUI project-settings panel). [sessions] is the
/// `sessions:[...]` array the server nests under each project when expanded.
class CodingProject {
  CodingProject({
    required this.id,
    required this.name,
    this.repoPath,
    this.host,
    this.deviceId,
    this.syncEnabled = false,
    this.syncDesktopPath,
    this.ignoreRules,
    this.defaultBranch,
    this.sessions = const [],
  });

  final String id;
  final String name;
  final String? repoPath;
  final String? host;
  final String? deviceId;
  final bool syncEnabled;
  final String? syncDesktopPath;
  final String? ignoreRules;
  final String? defaultBranch;
  final List<CodingSession> sessions;

  factory CodingProject.fromJson(Map<String, dynamic> j) {
    final rawSessions = (j['sessions'] as List?) ?? const [];
    return CodingProject(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      repoPath: _str(j['repo_path']),
      host: _str(j['host']),
      deviceId: _str(j['device_id']),
      syncEnabled: _asBool(j['sync_enabled']),
      syncDesktopPath: _str(j['sync_desktop_path']),
      ignoreRules: _str(j['ignore_rules']),
      defaultBranch: _str(j['default_branch']),
      sessions: rawSessions
          .whereType<Map>()
          .map((m) => CodingSession.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
    );
  }
}

/// A paired/registered device (`GET /api/devices`), used to populate the
/// sync "Device" dropdown. Offline devices are still listed but labelled.
///
/// `kind` ∈ `browser|desktop|mobile-ios|mobile-android`; `bridgeConnected` is
/// true when the device holds a live jc-client desktop agent WS. The sync
/// picker only shows sync-capable desktops — see [desktopCapable].
class CodingDevice {
  const CodingDevice({
    required this.id,
    required this.name,
    this.online = true,
    this.kind,
    this.bridgeConnected = false,
    this.syncCapable,
  });

  final String id;
  final String name;
  final bool online;
  final String? kind; // browser | desktop | mobile-ios | mobile-android
  final bool bridgeConnected;
  final bool? syncCapable; // server-computed: can run Mutagen sync

  /// Mobile pairings can NEVER run Mutagen file sync, yet they hold a bridge WS
  /// too (notifications/phone-control). Exclude ONLY these — a desktop jc-client
  /// usually registers with the default kind 'browser', so excluding 'browser'
  /// would drop the real desktop. Actual web browsers never hold a bridge, so
  /// they're filtered by [syncCapable]/[bridgeConnected], not by kind.
  static const _mobileKinds = {'mobile-ios', 'mobile-android', 'mobile'};

  /// Only desktops that can actually sync. Prefer the server's [syncCapable]
  /// flag; always exclude mobile kinds even if they hold a bridge.
  bool get desktopCapable {
    if (kind != null && _mobileKinds.contains(kind)) return false;
    if (syncCapable != null) return syncCapable!;
    return kind == 'desktop' || bridgeConnected;
  }

  factory CodingDevice.fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? j['device_id'] ?? '').toString();
    final name = _str(j['name']) ?? _str(j['device_name']) ?? (id.isEmpty ? 'device' : id);
    // Default online=true when absent (mirrors the web's `online !== false`).
    return CodingDevice(
      id: id,
      name: name,
      online: j['online'] == null ? true : _asBool(j['online']),
      kind: _str(j['kind'])?.toLowerCase(),
      bridgeConnected: _asBool(j['bridge_connected']),
      syncCapable: j['sync_capable'] == null ? null : _asBool(j['sync_capable']),
    );
  }
}

/// Live cross-device sync status for a session
/// (`GET /api/coding/session/$id/sync`).
///
/// `status` ∈ off|disconnected|idle|opening|syncing|synced|error. `total`/
/// `done` drive the progress bar while syncing; `lastSyncAt` is epoch seconds.
class CodingSyncStatus {
  const CodingSyncStatus({
    this.enabled = false,
    this.device,
    this.deviceOnline = false,
    this.status = 'off',
    this.total = 0,
    this.done = 0,
    this.conflicts = 0,
    this.lastSyncAt,
    this.error,
  });

  final bool enabled;
  final String? device;
  final bool deviceOnline;
  final String status;
  final int total;
  final int done;
  final int conflicts;
  final double? lastSyncAt; // epoch seconds
  final String? error;

  bool get isSyncing =>
      status == 'syncing' || status == 'opening' || status == 'connecting';

  /// Percent complete from Mutagen's staging progress (done/total files).
  int get pct => (isSyncing && total > 0)
      ? ((done / total) * 100).round()
      : (status == 'synced' ? 100 : 0);

  factory CodingSyncStatus.fromJson(Map<String, dynamic> j) {
    return CodingSyncStatus(
      enabled: _asBool(j['enabled']),
      device: _str(j['device']),
      deviceOnline: _asBool(j['device_online']),
      status: (j['status'] ?? 'off').toString(),
      total: _asInt(j['total']),
      done: _asInt(j['done']),
      conflicts: _asInt(j['conflicts']),
      lastSyncAt: _asDouble(j['last_sync_at']),
      error: _str(j['error']),
    );
  }
}

/// The `/api/coding/session/$id` payload — we only consume `session`
/// (the `subagents` UI was dropped to match the web).
class CodingSessionDetail {
  CodingSessionDetail({required this.session});

  final CodingSession session;

  factory CodingSessionDetail.fromJson(Map<String, dynamic> j) {
    final s = (j['session'] as Map?) ?? j;
    return CodingSessionDetail(
      session: CodingSession.fromJson(Map<String, dynamic>.from(s)),
    );
  }
}

// ── Chat transcript (GET /api/coding/session/$id/messages) ──────

/// One tool use inside an assistant chat message: name + one-line summary,
/// with the output snippet revealed when the card is expanded.
class CodingChatTool {
  const CodingChatTool({
    required this.name,
    this.summary = '',
    this.output = '',
    this.ok = true,
  });

  final String name;
  final String summary;
  final String output;
  final bool ok;

  factory CodingChatTool.fromJson(Map<String, dynamic> j) => CodingChatTool(
        name: (j['name'] ?? 'tool').toString(),
        summary: (j['summary'] ?? '').toString(),
        output: (j['output'] ?? '').toString(),
        ok: j['ok'] == null ? true : _asBool(j['ok']),
      );
}

/// One conversation message. `i` is the server's stable 0-based index —
/// pass `after=<count you already have>` to fetch only the new tail.
/// An assistant message may carry BOTH [text] and [tools].
class CodingChatMessage {
  const CodingChatMessage({
    required this.i,
    required this.role,
    this.text = '',
    this.tools = const [],
    this.ts,
  });

  final int i;
  final String role; // user | assistant
  final String text;
  final List<CodingChatTool> tools;
  final double? ts; // epoch seconds | null

  bool get isUser => role == 'user';

  factory CodingChatMessage.fromJson(Map<String, dynamic> j) {
    final rawTools = (j['tools'] as List?) ?? const [];
    return CodingChatMessage(
      i: _asInt(j['i']),
      role: (j['role'] ?? 'assistant').toString(),
      text: (j['text'] ?? '').toString(),
      tools: rawTools
          .whereType<Map>()
          .map((m) => CodingChatTool.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
      ts: _asDouble(j['ts']),
    );
  }
}

/// The `/messages` page payload: the (possibly partial) message tail plus the
/// session's live state so the chat header chip stays fresh without a second
/// poll. `source` is `live|cache` (informational).
class CodingChatPage {
  const CodingChatPage({
    this.messages = const [],
    this.total = 0,
    this.activityState,
    this.status = '',
    this.source,
  });

  final List<CodingChatMessage> messages;
  final int total;
  final String? activityState; // working | waiting | idle | null
  final String status;
  final String? source;

  factory CodingChatPage.fromJson(Map<String, dynamic> j) {
    final raw = (j['messages'] as List?) ?? const [];
    return CodingChatPage(
      messages: raw
          .whereType<Map>()
          .map((m) => CodingChatMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
      total: _asInt(j['total']),
      activityState: _str(j['activity_state']),
      status: (j['status'] ?? '').toString(),
      source: _str(j['source']),
    );
  }
}

/// One selectable option in an interactive prompt (`{key:'1', label:'Yes'}`).
/// Answering sends just [key] to the PTY — no newline.
class CodingPromptOption {
  const CodingPromptOption({required this.key, required this.label});

  final String key;
  final String label;

  factory CodingPromptOption.fromJson(Map<String, dynamic> j) =>
      CodingPromptOption(
        key: (j['key'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
      );
}

/// The `/prompt` payload — what Claude is currently asking in the pane (when
/// `activity_state == waiting`). [raw] is the pane tail, shown monospace when
/// no structured options were detected.
class CodingPromptState {
  const CodingPromptState({
    this.waiting = false,
    this.question,
    this.options = const [],
    this.raw,
  });

  final bool waiting;
  final String? question;
  final List<CodingPromptOption> options;
  final String? raw;

  /// A stable identity for "the same prompt" so a dismissed modal isn't
  /// re-popped on the next poll tick.
  String get signature =>
      '${question ?? ''}|${options.map((o) => o.key).join(',')}|${raw ?? ''}';

  factory CodingPromptState.fromJson(Map<String, dynamic> j) {
    final raw = (j['options'] as List?) ?? const [];
    return CodingPromptState(
      waiting: _asBool(j['waiting']),
      question: _str(j['question']),
      options: raw
          .whereType<Map>()
          .map((m) => CodingPromptOption.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
      raw: _str(j['raw']),
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

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse((v ?? '').toString()) ?? 0;
}

bool _asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = (v ?? '').toString().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}
