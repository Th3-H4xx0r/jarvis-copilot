import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/coding_sessions.dart';
import '../services/api_client.dart';
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

  static const Duration _refreshInterval = Duration(seconds: 4);

  // ── Sessions list ─────────────────────────────────────────────
  List<CodingSession> sessions = [];
  bool loading = false;
  String? error;

  // ── Selected session ──────────────────────────────────────────
  String? selectedId;
  CodingSession? selected;
  bool detailLoading = false;

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

  // ── Sessions list ─────────────────────────────────────────────
  Future<void> loadSessions() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      sessions = await _api.listSessions()
        ..sort((a, b) => (b.createdAt ?? 0).compareTo(a.createdAt ?? 0));
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

  // ── Select / inspect a session ────────────────────────────────
  Future<void> select(String id) async {
    if (selectedId != id) _teardownTerminal();
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
      if (selectedId == id) error = 'Could not load session: $e';
    } finally {
      if (selectedId == id) {
        detailLoading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(_refreshInterval, (_) => _refreshDetail());
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
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
            if (!_terminalText.isClosed) {
              _terminalText.add('\r\n\x1b[90m[detached]\x1b[0m\r\n');
            }
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
      terminalError = _msg(e);
      _terminalId = null;
    } finally {
      terminalStarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Send keystrokes from the xterm view to the PTY.
  void sendTerminalInput(String data) {
    final id = _terminalId;
    if (id == null || data.isEmpty) return;
    _api.terminalInput(id, data).catchError((_) {});
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
    _teardownTerminal();
    _terminalText.close();
    super.dispose();
  }
}
