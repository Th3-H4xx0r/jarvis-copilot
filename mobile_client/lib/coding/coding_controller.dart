import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/coding_sessions.dart';
import '../services/api_client.dart';
import 'coding_models.dart';

/// Drives the native Coding tab. Owns the sessions list, the selected
/// session's detail (status + subagents), and the launch/message/stop
/// actions. UI listens via [ChangeNotifier] and rebuilds on
/// [notifyListeners].
///
/// While a session is selected we poll `/api/coding/session/$id` every
/// [_refreshInterval] so status changes and newly-spawned subagents show
/// up without a manual refresh.
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
  List<CodingSubagent> subagents = [];
  bool detailLoading = false;

  // ── Action state ──────────────────────────────────────────────
  bool launching = false;
  bool sending = false;

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
      if (selectedId != null &&
          !sessions.any((s) => s.id == selectedId)) {
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
    selectedId = id;
    selected = sessions.cast<CodingSession?>().firstWhere(
          (s) => s?.id == id,
          orElse: () => null,
        );
    subagents = [];
    detailLoading = true;
    error = null;
    notifyListeners();
    await _refreshDetail();
    _startPolling();
  }

  void deselect() {
    _clearSelection();
    notifyListeners();
  }

  void _clearSelection() {
    _stopPolling();
    selectedId = null;
    selected = null;
    subagents = [];
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
      subagents = detail.subagents;
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
      );
      await loadSessions();
      if (session.id.isNotEmpty) {
        await select(session.id);
      }
      return session;
    } catch (e) {
      error = 'Could not launch session: $e';
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
      error = 'Could not send message: $e';
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  // ── Stop the session ──────────────────────────────────────────
  Future<void> stop() async {
    final id = selectedId;
    if (id == null) return;
    error = null;
    try {
      await _api.stop(id);
      await _refreshDetail();
      await loadSessions();
    } catch (e) {
      error = 'Could not stop session: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    super.dispose();
  }
}
