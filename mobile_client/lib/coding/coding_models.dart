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
  });

  final String id;
  final String? title;
  final String status; // starting | running | idle | stopped | error
  final String? host; // server | desktop
  final String? cwd;
  final String? branch;
  final String? claudeSessionId;
  final String? source;
  final String? model;
  final bool skipPermissions;
  final CodingSync? sync;
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
      model: _str(j['model']),
      skipPermissions: _asBool(j['skip_permissions']),
      sync: CodingSync.tryFromJson(j['sync']),
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

  /// Kinds that can NEVER run Mutagen file sync. Mobile clients hold a bridge
  /// WS too (notifications/phone-control), so `bridgeConnected` alone is not
  /// enough — exclude them explicitly.
  static const _nonDesktopKinds = {
    'mobile-ios', 'mobile-android', 'mobile', 'browser', 'web',
  };

  /// Only desktops that can actually sync. Prefer the server's [syncCapable]
  /// flag; always exclude mobile/browser kinds even if they hold a bridge.
  bool get desktopCapable {
    if (kind != null && _nonDesktopKinds.contains(kind)) return false;
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
