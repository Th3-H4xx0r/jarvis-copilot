import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/coding_sessions.dart';
import '../services/api_client.dart';
import '../services/app_lifecycle.dart';
import 'coding_models.dart';

/// Drives the native Coding tab. Owns the sessions list, the selected
/// session's detail (status), the launch/message/stop/restart/delete/settings
/// actions, and the live-terminal SSE lifecycle. UI listens via
/// [ChangeNotifier] and rebuilds on [notifyListeners].
///
/// While a session is selected we poll `/api/coding/session/$id` every
/// [_refreshInterval] so status changes show up without a manual refresh.
/// The live terminal runs in parallel: [startTerminal] attaches a server-side
/// PTY and streams its `output` events as [terminalText] for the UI's xterm
/// view to [write]; [sendTerminalInput]/[resizeTerminal] drive it back.
class CodingSessionsController extends ChangeNotifier {
  CodingSessionsController(ApiClient api) : _api = CodingSessionsApi(api);

  final CodingSessionsApi _api;

  /// The underlying REST wrapper — exposed for the Chat view's transcript /
  /// prompt polling (input still goes through [sendTerminalInput]).
  CodingSessionsApi get api => _api;

  static const Duration _refreshInterval = Duration(seconds: 4);

  // ── Projects → Sessions tree ──────────────────────────────────
  /// Registered projects, each carrying their nested sessions.
  List<CodingProject> projects = [];

  /// Project-less sessions (the synthetic "Ungrouped" bucket): legacy rows +
  /// device-discovered sessions.
  List<CodingSession> ungrouped = [];

  /// Flat session list derived from [projects] + [ungrouped]. Kept so the
  /// existing selection/terminal code (and any older callers) keep working.
  List<CodingSession> sessions = [];

  bool loading = false;
  String? error;

  /// Set of project ids (and the literal `__ungrouped__`) the user has
  /// collapsed in the tree. UI-only; persists for the controller's lifetime.
  final Set<String> collapsed = <String>{};

  /// Sentinel key for the synthetic Ungrouped group in [collapsed].
  static const String ungroupedKey = '__ungrouped__';

  bool busyProjects = false; // project create/update/delete/discover in flight

  // ── Paired devices (for the sync "Device" dropdown) ───────────
  /// Paired/registered devices, populated best-effort from `/api/devices`.
  /// Empty on error; never throws. The launch/settings sheets refresh this
  /// when they open via [loadDevices].
  List<CodingDevice> devices = [];

  // ── Selected session ──────────────────────────────────────────
  String? selectedId;
  CodingSession? selected;
  bool detailLoading = false;

  /// Live cross-device sync status for the selected session, polled alongside
  /// the detail refresh. Null until the first poll returns (or when the
  /// endpoint isn't available). Render the Sync card only when `sync.enabled`.
  CodingSyncStatus? sync;

  // ── Action state ──────────────────────────────────────────────
  bool launching = false;
  bool sending = false;
  bool busy = false; // stop/restart/delete in flight

  // ── Live terminal ─────────────────────────────────────────────
  /// Emits decoded PTY output text for the UI's xterm `Terminal` to write.
  Stream<String> get terminalText => _terminalText.stream;
  final StreamController<String> _terminalText =
      StreamController<String>.broadcast();
  String? _terminalId; // session id the terminal SSE is attached to
  StreamSubscription<Map<String, dynamic>>? _terminalSub;
  String? terminalError;
  bool terminalStarting = false;

  Timer? _poll;
  bool _disposed = false;

  bool get hasSelection => selectedId != null && selectedId!.isNotEmpty;

  // ── Projects → Sessions list ──────────────────────────────────
  /// Load the Projects→Sessions tree (`/projects?expand=sessions`) and derive
  /// the flat [sessions] list. Falls back to the flat `/sessions` endpoint when
  /// the projects payload is empty (older backends) so the page never breaks.
  /// Named [loadSessions] so the page's existing refresh wiring is unchanged.
  Future<void> loadSessions() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final view = await _api.listProjectsExpanded();
      projects = view.projects;
      ungrouped = view.ungrouped;
      final flat = <CodingSession>[
        for (final p in projects) ...p.sessions,
        ...ungrouped,
      ];
      if (flat.isEmpty) {
        // Older backend without the projects payload — fall back to flat list.
        try {
          ungrouped = await _api.listSessions();
          flat.addAll(ungrouped);
        } catch (_) {
          // keep flat empty; the (empty) projects view still renders fine
        }
      }
      sessions = flat..sort(_bySessionRecency);
      // If the selected session vanished from the list, clear it.
      if (selectedId != null && !sessions.any((s) => s.id == selectedId)) {
        _clearSelection();
      }
    } catch (e) {
      error = 'Could not load coding sessions: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Newest-first by numeric recency (epoch seconds; a string compare
  /// mis-ordered these). Prefers `last_activity_at`, falls back to `created_at`.
  static int _bySessionRecency(CodingSession a, CodingSession b) =>
      b.recencyTs.compareTo(a.recencyTs);

  /// Toggle a project group's collapsed state in the tree (UI-only).
  void toggleCollapsed(String key) {
    if (collapsed.contains(key)) {
      collapsed.remove(key);
    } else {
      collapsed.add(key);
    }
    notifyListeners();
  }

  bool isCollapsed(String key) => collapsed.contains(key);

  /// Best-effort refresh of the paired-devices list for the sync dropdown.
  /// Never throws — on any error the list is left empty. Call when opening the
  /// launch or settings sheet (and once on init).
  Future<void> loadDevices() async {
    try {
      final next = await _api.listDevices();
      if (_disposed) return;
      devices = next;
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      devices = const [];
      notifyListeners();
    }
  }

  // ── Select / inspect a session ────────────────────────────────
  Future<void> select(String id) async {
    if (selectedId != id) {
      _teardownTerminal();
      sync = null; // drop the previous session's sync status until the poll lands
    }
    selectedId = id;
    selected = sessions.cast<CodingSession?>().firstWhere(
          (s) => s?.id == id,
          orElse: () => null,
        );
    detailLoading = true;
    error = null;
    notifyListeners();
    await _refreshDetail();
    _startPolling();
  }

  void deselect() {
    _teardownTerminal();
    _clearSelection();
    notifyListeners();
  }

  void _clearSelection() {
    _stopPolling();
    selectedId = null;
    selected = null;
    sync = null;
    detailLoading = false;
  }

  Future<void> _refreshDetail() async {
    final id = selectedId;
    if (id == null) return;
    try {
      final detail = await _api.get(id);
      // Guard against a late response after the user switched/cleared.
      if (selectedId != id) return;
      selected = detail.session;
      error = null;
    } catch (e) {
      if (selectedId != id) return;
      // This runs on EVERY poll tick, so a single transient blip (a 5xx from
      // the edge when the webui is momentarily busy, or a dropped connection)
      // must NOT flash a scary banner while we already have the session loaded
      // — keep showing the cached detail; the next tick recovers. Only surface
      // an error when there's nothing to show yet, or it's a real failure
      // (e.g. a 404 for a deleted session).
      if (selected != null && _isTransient(e)) return;  // silent, keep cached
      error = 'Could not load session: ${_msg(e)}';
    } finally {
      if (selectedId == id) {
        detailLoading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// A transient, self-recovering failure (a 5xx from the edge/upstream while
  /// the webui is briefly busy, or a connection/timeout) vs. a real error worth
  /// surfacing (4xx). Used so poll-driven refreshes don't flash error banners.
  bool _isTransient(Object e) {
    if (e is! DioException) return false;
    final code = e.response?.statusCode;
    if (code != null) return code >= 500;  // 502/503/504 etc.
    return e.type != DioExceptionType.badResponse;  // no response = conn/timeout
  }

  /// Poll the live sync status for the selected session. Best-effort: a missing
  /// endpoint / transient error leaves the last value in place. Notifies only
  /// when the status actually changed so we don't churn the UI every tick.
  Future<void> _refreshSync() async {
    final id = selectedId;
    if (id == null) return;
    try {
      final next = await _api.syncStatus(id);
      if (selectedId != id || _disposed) return;
      final prev = sync;
      sync = next;
      final changed = prev == null ||
          prev.enabled != next.enabled ||
          prev.deviceOnline != next.deviceOnline ||
          prev.status != next.status ||
          prev.total != next.total ||
          prev.done != next.done ||
          prev.device != next.device ||
          prev.error != next.error;
      if (changed) notifyListeners();
    } catch (_) {
      // Endpoint unavailable / transient — keep the last known status.
    }
  }

  void _startPolling() {
    _stopPolling();
    // Kick both polls immediately so the Sync card appears without a 4s wait.
    _refreshSync();
    _poll = Timer.periodic(_refreshInterval, (_) {
      _refreshDetail();
      _refreshSync();
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  // ── Quiet list poll (live status while the tab is open) ───────────────────
  Timer? _listPoll;
  static const Duration _listPollInterval = Duration(seconds: 5);

  /// Start/stop a quiet periodic refresh of the whole sessions list so the dots
  /// stay live (working/waiting/idle) without a pull-to-refresh. Quiet = no
  /// loading spinner; only ticks while the app is in the foreground.
  void setListPolling(bool on) {
    _listPoll?.cancel();
    _listPoll = null;
    if (on && !_disposed) {
      _listPoll = Timer.periodic(_listPollInterval, (_) {
        if (AppLifecycle.isForeground) _refreshSessionsQuiet();
      });
    }
  }

  Future<void> _refreshSessionsQuiet() async {
    if (_disposed) return;
    try {
      final view = await _api.listProjectsExpanded();
      if (_disposed) return;
      final flat = <CodingSession>[
        for (final p in view.projects) ...p.sessions,
        ...view.ungrouped,
      ];
      if (flat.isEmpty) return; // don't wipe a good list on an empty/old payload
      projects = view.projects;
      ungrouped = view.ungrouped;
      sessions = flat..sort(_bySessionRecency);
      if (selectedId != null && !sessions.any((s) => s.id == selectedId)) {
        _clearSelection();
      }
      notifyListeners();
    } catch (_) {
      // transient — keep current data, retry next tick
    }
  }

  // ── Launch ────────────────────────────────────────────────────
  Future<CodingSession?> launch({
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
    launching = true;
    error = null;
    notifyListeners();
    try {
      final session = await _api.launch(
        cwd: cwd,
        repoPath: repoPath,
        worktree: worktree,
        title: title,
        prompt: prompt,
        model: model,
        host: host,
        skipPermissions: skipPermissions,
        sync: sync,
      );
      await loadSessions();
      if (session.id.isNotEmpty) {
        await select(session.id);
      }
      return session;
    } catch (e) {
      error = 'Could not launch session: ${_msg(e)}';
      return null;
    } finally {
      launching = false;
      notifyListeners();
    }
  }

  // ── Projects (create / settings / delete / new-session) ───────

  /// Create a project. Returns its new id (or null on failure / error set).
  Future<String?> createProject({
    required String name,
    required String repoPath,
    String? defaultBranch,
  }) async {
    busyProjects = true;
    error = null;
    notifyListeners();
    try {
      final id = await _api.createProject(
        name: name,
        repoPath: repoPath,
        defaultBranch: defaultBranch,
      );
      await loadSessions();
      return id;
    } catch (e) {
      error = 'Could not create project: ${_msg(e)}';
      return null;
    } finally {
      busyProjects = false;
      notifyListeners();
    }
  }

  /// Rename / set sync / branch / ignore rules on a project. Returns true on
  /// success.
  Future<bool> updateProject(
    String id, {
    String? name,
    String? defaultBranch,
    bool? syncEnabled,
    String? syncDesktopPath,
    String? ignoreRules,
    String? deviceId,
  }) async {
    busyProjects = true;
    error = null;
    notifyListeners();
    try {
      await _api.updateProject(
        id,
        name: name,
        defaultBranch: defaultBranch,
        syncEnabled: syncEnabled,
        syncDesktopPath: syncDesktopPath,
        ignoreRules: ignoreRules,
        deviceId: deviceId,
      );
      await loadSessions();
      return true;
    } catch (e) {
      error = 'Could not save project: ${_msg(e)}';
      return false;
    } finally {
      busyProjects = false;
      notifyListeners();
    }
  }

  /// Delete a project. `cascade` stops + removes its sessions; otherwise they
  /// become Ungrouped. Returns true on success.
  Future<bool> deleteProject(String id, {bool cascade = false}) async {
    busyProjects = true;
    error = null;
    notifyListeners();
    try {
      await _api.deleteProject(id, cascade: cascade);
      await loadSessions();
      return true;
    } catch (e) {
      error = 'Could not delete project: ${_msg(e)}';
      return false;
    } finally {
      busyProjects = false;
      notifyListeners();
    }
  }

  /// Launch a new session inside a project (cwd defaults server-side to the
  /// project's repo_path). On success refreshes the tree and opens the session.
  Future<CodingSession?> launchInProject(
    String projectId, {
    String? cwd,
    String? title,
    String? prompt,
    String? model,
    String? host,
    bool skipPermissions = false,
    CodingSync? sync,
  }) async {
    launching = true;
    error = null;
    notifyListeners();
    try {
      final session = await _api.launchInProject(
        projectId,
        cwd: cwd,
        title: title,
        prompt: prompt,
        model: model,
        host: host,
        skipPermissions: skipPermissions,
        sync: sync,
      );
      // Make sure the project is expanded so the new session is visible.
      collapsed.remove(projectId);
      await loadSessions();
      if (session.id.isNotEmpty) {
        await select(session.id);
      }
      return session;
    } catch (e) {
      error = 'Could not launch session: ${_msg(e)}';
      return null;
    } finally {
      launching = false;
      notifyListeners();
    }
  }

  /// Resume a discovered-transcript (past) session on its device, then refresh.
  /// On success selects the resumed session (which may carry a new id) so the
  /// detail pane picks up the live terminal once it reports running. Returns the
  /// id to open, or null on failure (error is set).
  Future<String?> resumeSession(String id) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final resumed = await _api.resume(id);
      final openId = (resumed != null && resumed.id.isNotEmpty) ? resumed.id : id;
      await loadSessions();
      return openId;
    } catch (e) {
      error = 'Could not resume session: ${_msg(e)}';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Relaunch an ENDED session on its DEVICE — a fresh tmux in the same folder,
  /// resuming its transcript. Mirrors the WebUI's `codingRelaunchDevice`; selects
  /// the new live session on success so its terminal mounts.
  Future<void> relaunchOnDevice() async {
    final s = selected;
    if (s == null) return;
    final cwd = s.cwd ?? '';
    if (cwd.isEmpty) {
      error = 'Can’t relaunch — this session has no folder. Try “Resume on server”.';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final sess = await _api.relaunchOnDevice(
        projectId: s.projectId,
        cwd: cwd,
        title: s.title,
        resumeSessionId: s.claudeSessionId,
      );
      await loadSessions();
      if (sess != null && sess.id.isNotEmpty) {
        await select(sess.id);
      }
    } catch (e) {
      error = 'Relaunch failed: ${_msg(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Re-attempt the live-terminal attach for a session whose terminal ended —
  /// re-fetches the detail so a session that's come back to life re-mounts its
  /// terminal (the page watches the selection); a still-ended one stays on the
  /// recovery panel. Mirrors the WebUI's `codingReopenTerminal`.
  Future<void> reopenTerminal() async {
    final id = selectedId;
    if (id == null) return;
    _teardownTerminal();
    await _refreshDetail();
    notifyListeners();
  }

  /// Ask the paired device to re-scan its sessions, then refresh the tree.
  /// Discovery is async over the bridge, so we refresh now and again shortly
  /// after. Best-effort: failures surface as [error] but never throw.
  Future<void> discoverRefresh() async {
    busyProjects = true;
    notifyListeners();
    try {
      await _api.discoverRefresh();
    } catch (e) {
      error = 'Rescan request failed: ${_msg(e)}';
    } finally {
      busyProjects = false;
      notifyListeners();
    }
    await loadSessions();
    // Give the device a beat to report back over the bridge, then refresh again.
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!_disposed) loadSessions();
    });
  }

  // ── Send a message into the session ───────────────────────────
  Future<void> send(String text) async {
    final id = selectedId;
    final trimmed = text.trim();
    if (id == null || trimmed.isEmpty || sending) return;
    sending = true;
    error = null;
    notifyListeners();
    try {
      await _api.sendMessage(id, trimmed);
      await _refreshDetail();
    } catch (e) {
      error = 'Could not send message: ${_msg(e)}';
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  // ── Stop the session ──────────────────────────────────────────
  Future<void> stop() async {
    final id = selectedId;
    if (id == null || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.stop(id);
      await _refreshDetail();
      await loadSessions();
    } catch (e) {
      error = 'Could not stop session: ${_msg(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ── Restart the session (claude --continue) ───────────────────
  Future<void> restart() async {
    final id = selectedId;
    if (id == null || busy) return;
    busy = true;
    error = null;
    // Tear the terminal down so it re-attaches to the NEW tmux on next start.
    _teardownTerminal();
    notifyListeners();
    try {
      await _api.restart(id);
      await _refreshDetail();
      await loadSessions();
    } catch (e) {
      error = 'Could not restart session: ${_msg(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Stop + permanently remove. On success the selection is cleared and the
  /// list refreshed; returns true so the UI can pop back to the list.
  Future<bool> delete() async {
    final id = selectedId;
    if (id == null || busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.delete(id);
      _teardownTerminal();
      _clearSelection();
      await loadSessions();
      return true;
    } catch (e) {
      error = 'Could not delete session: ${_msg(e)}';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Save per-session settings. Tolerates a 404 (endpoint not deployed yet) by
  /// surfacing a friendly note rather than a hard error. Returns true on a
  /// real success.
  Future<bool> saveSettings({
    bool? skipPermissions,
    CodingSync? sync,
    String? cwd,
  }) async {
    final id = selectedId;
    if (id == null) return false;
    error = null;
    notifyListeners();
    try {
      await _api.updateSettings(
        id,
        skipPermissions: skipPermissions,
        sync: sync,
        cwd: cwd,
      );
      await _refreshDetail();
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        error = 'Saving settings isn’t available on this server yet.';
      } else {
        error = 'Could not save settings: ${_msg(e)}';
      }
      notifyListeners();
      return false;
    } catch (e) {
      error = 'Could not save settings: ${_msg(e)}';
      notifyListeners();
      return false;
    }
  }

  /// Kick a fresh sync pass for the selected session, then re-poll the status.
  /// Best-effort — errors are swallowed (the status poll surfaces any issue).
  Future<void> refreshSync() async {
    final id = selectedId;
    if (id == null) return;
    try {
      await _api.refreshSync(id);
    } catch (_) {
      // ignore — the status refresh below reflects reality
    }
    await _refreshSync();
  }

  // ── Live terminal ─────────────────────────────────────────────

  /// Attach a server-side PTY to the selected session's tmux and stream its
  /// output. Idempotent for a given session id. Safe to call once the xterm
  /// view is mounted; output arrives via [terminalText].
  Future<void> startTerminal({int rows = 24, int cols = 80}) async {
    final id = selectedId;
    if (id == null) return;
    if (_terminalId == id) return; // already attached to this session
    _teardownTerminal();
    _terminalId = id;
    terminalStarting = true;
    terminalError = null;
    notifyListeners();
    try {
      await _api.terminalStart(id, rows: rows, cols: cols);
      if (selectedId != id) {
        _teardownTerminal();
        return;
      }
      _terminalSub = _api.terminalOutput(id).listen(
        (ev) {
          final event = (ev['event'] ?? 'message').toString();
          if (event == 'output') {
            final text = (ev['text'] ?? '').toString();
            if (text.isNotEmpty && !_terminalText.isClosed) {
              _terminalText.add(text);
            }
          } else if (event == 'terminal_closed') {
            final reason = (ev['reason'] ?? '').toString();
            if (!_terminalText.isClosed) {
              final msg = reason == 'ended'
                  ? '[session ended — claude is no longer running; reopen to relaunch]'
                  : reason == 'disconnected'
                      ? '[disconnected — your Mac dropped its connection; reopen when it’s back]'
                      : '[detached — reopen this session to resume the live terminal]';
              _terminalText.add('\r\n\x1b[90m$msg\x1b[0m\r\n');
            }
            // Reset the attach guard so re-tapping the session re-attaches (the
            // old bug: _terminalId stayed set, so reopen was a no-op forever).
            _terminalSub?.cancel();
            _terminalSub = null;
            _terminalId = null;
            terminalStarting = false;
            notifyListeners();
          } else if (event == 'terminal_error') {
            final msg = (ev['error'] ?? '').toString();
            if (msg.isNotEmpty && !_terminalText.isClosed) {
              _terminalText.add('\r\n\x1b[91m[terminal error: $msg]\x1b[0m\r\n');
            }
          }
        },
        onError: (_) {
          // Transient stream drop — leave the last buffer in place.
        },
        cancelOnError: false,
      );
    } catch (e) {
      // A discovered Mac session whose device is OFFLINE can't be attached live
      // (no process to attach to) — point the user at resume-to-server.
      final offline = e is DioException &&
          e.response?.statusCode == 409 &&
          e.response?.data is Map &&
          (e.response!.data as Map)['can_resume'] == true;
      terminalError = offline
          ? 'Your Mac is offline — resume this session on the server to keep working.'
          : _msg(e);
      _terminalId = null;
    } finally {
      terminalStarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Send keystrokes from the xterm view / chat prompt to the PTY.
  ///
  /// Returns whether the bytes actually reached the server. If the attach has
  /// dropped (another device took over the single-viewer terminal, or the
  /// stream closed), it RE-ATTACHES first instead of silently no-oping — the
  /// old behavior made chat-mode prompt answers vanish into the void.
  Future<bool> sendTerminalInput(String data) async {
    if (data.isEmpty) return false;
    if (_terminalId == null) {
      await startTerminal();
    }
    final id = _terminalId;
    if (id == null) return false;
    try {
      await _api.terminalInput(id, data);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Push the xterm view's dimensions to the PTY.
  void resizeTerminal({required int rows, required int cols}) {
    final id = _terminalId;
    if (id == null) return;
    _api.terminalResize(id, rows: rows, cols: cols).catchError((_) {});
  }

  void _teardownTerminal() {
    _terminalSub?.cancel();
    _terminalSub = null;
    final id = _terminalId;
    if (id != null) {
      // Detach the server-side PTY (does NOT kill the tmux session / claude).
      _api.terminalClose(id).catchError((_) {});
    }
    _terminalId = null;
    terminalStarting = false;
  }

  /// Detach the live terminal (server PTY + SSE) WITHOUT refreshing — used when a
  /// session transitions to ENDED while viewed, so the now-dead tmux's stream/PTY
  /// isn't left dangling with no consumer. Idempotent. Mirrors the WebUI ended-
  /// render's `_codingTeardownTerminal()`.
  void detachTerminal() => _teardownTerminal();

  String _msg(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['error'] != null) return data['error'].toString();
      if (data is String && data.trim().isNotEmpty) return data.trim();
      return e.message ?? e.toString();
    }
    if (e is StateError) return e.message;
    return e.toString();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _listPoll?.cancel();
    _teardownTerminal();
    _terminalText.close();
    super.dispose();
  }
}
