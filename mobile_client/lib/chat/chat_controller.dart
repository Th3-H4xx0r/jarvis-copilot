import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/chat.dart';
import '../api/sessions.dart';
import '../main.dart' as app;
import '../services/api_client.dart';
import '../services/invoke_runner.dart';
import '../services/local_ai_settings.dart';
import '../services/model_selection.dart';
import '../services/on_device_ai.dart';
import '../services/on_device_ai_types.dart';
import 'chat_models.dart';

/// Drives the native chat screen. Owns the sessions list, the active
/// session's messages, and the live streaming turn. UI listens via
/// [ChangeNotifier] and rebuilds on [notifyListeners].
///
/// The streaming model mirrors the webui: POST /api/chat/start returns a
/// stream_id, then GET /api/chat/stream (SSE) delivers token/tool/done
/// events which we fold into the trailing assistant [ChatMessage].
class ChatController extends ChangeNotifier {
  ChatController(ApiClient api)
      : _chat = ChatApi(api),
        _sessions = SessionsApi(api);

  final ChatApi _chat;
  final SessionsApi _sessions;

  // ── Sessions ──────────────────────────────────────────────────
  List<ChatSessionSummary> sessions = [];
  bool sessionsLoading = false;

  // ── Active session ────────────────────────────────────────────
  String? sessionId;
  String sessionTitle = 'New chat';
  final List<ChatMessage> messages = [];
  bool historyLoading = false;

  // ── Streaming turn ────────────────────────────────────────────
  bool streaming = false;
  String? _streamId;
  StreamSubscription<Map<String, dynamic>>? _sub;
  ChatMessage? _live; // the assistant message currently being filled
  String? error;

  // Live usage from `metering` events (tokens / cost), shown subtly.
  int? inputTokens;
  int? outputTokens;
  double? estimatedCost;

  bool get hasSession => sessionId != null && sessionId!.isNotEmpty;
  bool get isEmpty => messages.isEmpty && !historyLoading;

  // ── Sessions list ─────────────────────────────────────────────
  Future<void> loadSessions() async {
    sessionsLoading = true;
    notifyListeners();
    try {
      final raw = await _sessions.list();
      sessions = raw
          .map((m) => ChatSessionSummary.fromJson(m))
          .where((s) => !s.archived && s.id.isNotEmpty)
          .toList()
        ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
    } catch (e) {
      error = 'Could not load chats: $e';
    } finally {
      sessionsLoading = false;
      notifyListeners();
    }
  }

  /// Open the most recent session, or start a fresh one if there are
  /// none. Called once when the chat tab first appears.
  Future<void> openInitial() async {
    if (hasSession) return;
    await loadSessions();
    if (sessions.isNotEmpty) {
      await openSession(sessions.first.id);
    } else {
      startNewSession();
    }
  }

  // ── Open / switch session ─────────────────────────────────────
  Future<void> openSession(String id) async {
    if (streaming) await cancel();
    sessionId = id;
    error = null;
    messages.clear();
    historyLoading = true;
    inputTokens = outputTokens = null;
    estimatedCost = null;
    final summary = sessions.where((s) => s.id == id).cast<ChatSessionSummary?>().firstWhere(
          (s) => s != null,
          orElse: () => null,
        );
    sessionTitle = summary?.displayTitle ?? 'Chat';
    notifyListeners();
    try {
      final data = await _sessions.get(id);
      final session = (data?['session'] as Map?) ?? data;
      final title = (session?['title'] ?? '').toString().trim();
      if (title.isNotEmpty) sessionTitle = title;
      final rawMessages = (session?['messages'] as List?) ?? const [];
      _hydrateHistory(rawMessages);
    } catch (e) {
      error = 'Could not open chat: $e';
    } finally {
      historyLoading = false;
      notifyListeners();
    }
  }

  void _hydrateHistory(List<dynamic> raw) {
    messages.clear();
    // Index tool-role results by their tool_call_id so we can fold them
    // into the matching tool block as it's parsed.
    final toolResults = <String, String>{};
    for (final m in raw) {
      if (m is Map && (m['role'] ?? '') == 'tool') {
        final id = (m['tool_call_id'] ?? '').toString();
        if (id.isNotEmpty) {
          toolResults[id] = (m['content'] ?? '').toString();
        }
      }
    }
    for (final m in raw) {
      if (m is! Map) continue;
      final msg = ChatMessage.fromStored(Map<String, dynamic>.from(m));
      if (msg == null) continue;
      for (final block in msg.blocks) {
        if (block is ToolBlock && block.tool.callId != null) {
          final res = toolResults[block.tool.callId];
          if (res != null && res.isNotEmpty) block.tool.result = res;
        }
      }
      messages.add(msg);
    }
  }

  // ── New session ───────────────────────────────────────────────
  /// Stage a brand-new conversation. We defer the actual POST
  /// /api/session/new until the first message, matching the webui's
  /// "empty session writes nothing to disk" behaviour.
  void startNewSession() {
    if (streaming) unawaited(cancel());
    sessionId = null;
    sessionTitle = 'New chat';
    messages.clear();
    error = null;
    inputTokens = outputTokens = null;
    estimatedCost = null;
    notifyListeners();
  }

  Future<String> _ensureSession() async {
    if (hasSession) return sessionId!;
    final created = await _sessions.create();
    final session = (created['session'] as Map?) ?? created;
    final id = (session['session_id'] ?? '').toString();
    if (id.isEmpty) throw StateError('Could not create a chat session');
    sessionId = id;
    return id;
  }

  // ── Send a message ────────────────────────────────────────────
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || streaming) return;
    error = null;

    messages.add(ChatMessage.user(trimmed));
    final assistant = ChatMessage(role: 'assistant', streaming: true);
    messages.add(assistant);
    _live = assistant;
    streaming = true;
    notifyListeners();

    try {
      // On-device first: if the local layer fully handles the turn, we never
      // hit the server. Any miss/escalation/error falls through transparently.
      if (LocalAiSettings.instance.enabledForChat &&
          await _tryLocal(trimmed, assistant)) {
        return;
      }

      final id = await _ensureSession();
      final start = await _chat.startMessage(
        sessionId: id,
        text: trimmed,
        model: ModelSelection.instance.modelFor(VoiceSurface.chat),
        provider: ModelSelection.instance.providerFor(VoiceSurface.chat),
      );
      _streamId = (start['stream_id'] ?? '').toString();
      if (_streamId == null || _streamId!.isEmpty) {
        throw StateError('Server did not start a stream');
      }
      _sub = _chat.streamEvents(_streamId!).listen(
            _onEvent,
            onError: _onStreamError,
            onDone: _onStreamDone,
            cancelOnError: true,
          );
    } catch (e) {
      _failLive('$e');
    }
  }

  /// Attempt to handle [text] entirely on-device. Returns true if handled
  /// (answer or local tool call); false to escalate to the server. Never
  /// throws — any failure returns false so the server path runs.
  Future<bool> _tryLocal(String text, ChatMessage assistant) async {
    try {
      final result = await app.localRouter.handle(text, VoiceSurface.chat);
      switch (result) {
        case DirectAnswer():
          assistant.onDevice = LocalAiSettings.instance.showBadge;
          // Stream the FULL reply from the model (the guided-gen inline answer
          // is a short field that truncates long content like poems).
          await _streamLocalReply(text, assistant);
          _finishLive();
          unawaited(_persistLocal(text, assistant.plainText));
          return true;

        case ToolCall(:final name, :final args, :final requiresConfirm, :final confirmation):
          // Outward/destructive actions defer to the server's approval flow.
          if (requiresConfirm) return false;
          final tool = ToolInvocation(name: name, args: args);
          assistant.startTool(tool);
          notifyListeners();
          final InvokeResult res = await app.runner.run(name, args);
          final ok = res.error == null;
          assistant.completeTool(name: name, isError: !ok);
          final summary = ok
              ? (confirmation?.isNotEmpty == true ? confirmation! : _summarize(res.result))
              : (res.error ?? 'failed');
          if (summary.isNotEmpty) assistant.appendToken(summary);
          assistant.onDevice = LocalAiSettings.instance.showBadge;
          _finishLive();
          unawaited(_persistLocal(text, assistant.plainText));
          return true;

        case Escalate():
          return false;
      }
    } catch (e) {
      debugPrint('[chat] local route failed, escalating: $e');
      return false;
    }
  }

  /// Persist a completed on-device turn into the server session so it shows on
  /// the web + other devices. Best-effort.
  Future<void> _persistLocal(String userText, String assistantText) async {
    try {
      final sid = await _ensureSession();
      await _sessions.appendLocalTurn(sid, user: userText, assistant: assistantText);
    } catch (_) {}
  }

  /// Stream a full reply from the on-device model (persona assistant prompt)
  /// into [assistant]. Used when the router decided to answer locally.
  Future<void> _streamLocalReply(String userText, ChatMessage assistant) async {
    final req = LocalRequest(
      userText: userText,
      surface: VoiceSurface.chat,
      toolCatalogJson: '[]',
      tier: LocalAiTier.fullLocalFirst,
    );
    final completer = Completer<void>();
    OnDeviceAi.instance.generate(req).listen(
      (t) {
        assistant.appendToken(t);
        notifyListeners();
      },
      onError: (_) => completer.complete(),
      onDone: () => completer.complete(),
      cancelOnError: true,
    );
    await completer.future;
    if (assistant.plainText.trim().isEmpty) {
      assistant.appendToken('At your service.');
    }
  }

  static String _summarize(Object? result) {
    if (result == null) return 'Done.';
    if (result is String) return result;
    if (result is Map) {
      final note = result['note'] ?? result['message'] ?? result['result'];
      if (note != null) return note.toString();
    }
    return 'Done.';
  }

  void _onEvent(Map<String, dynamic> ev) {
    final live = _live;
    if (live == null) return;
    final type = (ev['event'] ?? '').toString();
    switch (type) {
      case 'token':
        final t = (ev['text'] ?? '').toString();
        if (t.isNotEmpty) {
          live.appendToken(t);
          notifyListeners();
        }
        break;
      case 'reasoning':
        live.reasoning += (ev['text'] ?? '').toString();
        notifyListeners();
        break;
      case 'tool':
        live.startTool(ToolInvocation(
          name: (ev['name'] ?? 'tool').toString(),
          preview: ev['preview']?.toString(),
          args: ev['args'] is Map
              ? Map<String, dynamic>.from(ev['args'] as Map)
              : const {},
        ));
        notifyListeners();
        break;
      case 'tool_complete':
        live.completeTool(
          name: ev['name']?.toString(),
          durationSec: _asDouble(ev['duration']),
          isError: ev['is_error'] == true,
          preview: ev['preview']?.toString(),
        );
        notifyListeners();
        break;
      case 'interim_assistant':
        // Only adopt interim text if nothing has streamed yet — avoids
        // double-printing when tokens already arrived.
        if (ev['already_streamed'] != true && live.plainText.isEmpty) {
          final t = (ev['text'] ?? '').toString();
          if (t.isNotEmpty) {
            live.appendToken(t);
            notifyListeners();
          }
        }
        break;
      case 'metering':
        _applyMetering(ev);
        break;
      case 'title':
        final t = (ev['title'] ?? '').toString().trim();
        if (t.isNotEmpty) {
          sessionTitle = t;
          notifyListeners();
        }
        break;
      case 'apperror':
      case 'error':
        _failLive((ev['message'] ?? ev['error'] ?? 'Request failed').toString());
        break;
      case 'cancel':
        _finishLive(cancelled: true);
        break;
      case 'done':
        _applyMetering(ev);
        // The done payload carries the authoritative session; pick up a
        // freshly generated title if we don't have one yet.
        final session = ev['session'];
        if (session is Map) {
          final t = (session['title'] ?? '').toString().trim();
          if (t.isNotEmpty) sessionTitle = t;
        }
        _finishLive();
        break;
      default:
        break;
    }
  }

  void _applyMetering(Map<String, dynamic> ev) {
    final usage = (ev['usage'] is Map)
        ? Map<String, dynamic>.from(ev['usage'] as Map)
        : ev;
    final inp = _asInt(usage['input_tokens']);
    final out = _asInt(usage['output_tokens']);
    final cost = _asDouble(usage['estimated_cost']);
    var changed = false;
    if (inp != null && inp != inputTokens) {
      inputTokens = inp;
      changed = true;
    }
    if (out != null && out != outputTokens) {
      outputTokens = out;
      changed = true;
    }
    if (cost != null && cost != estimatedCost) {
      estimatedCost = cost;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _onStreamError(Object e, [StackTrace? st]) => _failLive('$e');

  void _onStreamDone() {
    // SSE socket closed without an explicit done/cancel — finalize so
    // the UI doesn't hang on a spinner.
    if (streaming) _finishLive();
  }

  void _finishLive({bool cancelled = false}) {
    final live = _live;
    if (live != null) {
      live.streaming = false;
      // Drop a trailing empty text block left by a tool-only turn.
      live.blocks.removeWhere((b) => b is TextBlock && b.isEmpty);
      if (live.blocks.isEmpty && live.reasoning.isEmpty && !live.isError) {
        if (cancelled) {
          live.blocks.add(TextBlock('_(cancelled)_'));
        }
      }
    }
    _teardownStream();
    unawaited(_refreshSessionRow());
    notifyListeners();
  }

  void _failLive(String message) {
    final live = _live;
    if (live != null) {
      live.streaming = false;
      live.isError = true;
      live.blocks
        ..removeWhere((b) => b is TextBlock && b.isEmpty)
        ..add(TextBlock(message));
    } else {
      error = message;
    }
    _teardownStream();
    notifyListeners();
  }

  void _teardownStream() {
    _sub?.cancel();
    _sub = null;
    _live = null;
    _streamId = null;
    streaming = false;
  }

  /// After a turn settles, refresh this session's row in the list (title
  /// + ordering) without blocking the UI.
  Future<void> _refreshSessionRow() async {
    try {
      await loadSessions();
    } catch (_) {/* best-effort */}
  }

  // ── Stop / cancel ─────────────────────────────────────────────
  Future<void> cancel() async {
    final sid = _streamId;
    _finishLive(cancelled: true);
    if (sid != null) {
      try {
        await _chat.cancel(sid);
      } catch (_) {/* the stream is already torn down locally */}
    }
  }

  // ── Session mutations ─────────────────────────────────────────
  Future<void> renameSession(String id, String title) async {
    await _sessions.rename(id, title);
    if (id == sessionId) sessionTitle = title;
    final idx = sessions.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      final s = sessions[idx];
      sessions[idx] = ChatSessionSummary(
        id: s.id,
        title: title,
        messageCount: s.messageCount,
        updatedAt: s.updatedAt,
        model: s.model,
        modelProvider: s.modelProvider,
        pinned: s.pinned,
        archived: s.archived,
      );
    }
    notifyListeners();
  }

  Future<void> deleteSession(String id) async {
    // The server deletes via POST /api/session/delete (not the DELETE
    // verb) with the id in the JSON body — matches the webui client.
    await _chat.api.postJson('/api/session/delete', {'session_id': id});
    sessions.removeWhere((s) => s.id == id);
    if (id == sessionId) {
      if (sessions.isNotEmpty) {
        await openSession(sessions.first.id);
      } else {
        startNewSession();
      }
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

double? _asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
