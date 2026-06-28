import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../api/chat.dart';
import '../api/sessions.dart';
import '../main.dart' as app;
import '../services/api_client.dart';
import '../services/chat_sync_bus.dart';
import '../services/invoke_runner.dart';
import '../services/local_ai_settings.dart';
import '../services/model_selection.dart';
import '../services/on_device_ai.dart';
import '../services/on_device_ai_types.dart';
import '../widgets/composer_attach.dart';
import 'chat_models.dart';

/// Drives the native chat screen. Owns the sessions list, the active
/// session's messages, and the live streaming turn. UI listens via
/// [ChangeNotifier] and rebuilds on [notifyListeners].
///
/// The streaming model mirrors the webui: POST /api/chat/start returns a
/// stream_id, then GET /api/chat/stream (SSE) delivers token/tool/done
/// events which we fold into the trailing assistant [ChatMessage].
class ChatController extends ChangeNotifier implements ComposerAttachHost {
  ChatController(ApiClient api)
      : _chat = ChatApi(api),
        _sessions = SessionsApi(api) {
    // Live chats: refresh when a turn is added elsewhere (e.g. a voice
    // conversation persists to a session). See [ChatSyncBus].
    _syncSub = ChatSyncBus.instance.onChanged.listen(_onSessionChanged);
  }

  final ChatApi _chat;
  final SessionsApi _sessions;

  StreamSubscription<String?>? _syncSub;
  Timer? _listPoll;
  bool _disposed = false;

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
  // The on-device generation subscription, kept so [_teardownStream] can cancel
  // it (which triggers OnDeviceAi's onCancel → native cancel(requestId)). Held
  // separately from [_sub] because the local path doesn't use the SSE stream.
  StreamSubscription<String>? _localSub;
  // Completes the in-flight [_streamLocalReply] future when the stream is torn
  // down (Stop), so the awaiting send() returns instead of hanging.
  Completer<void>? _localDone;
  ChatMessage? _live; // the assistant message currently being filled
  DateTime? _turnStartedAt; // for the per-message "Done in Xs" status
  String? error;

  // ── Composer attachments (photos / videos / files) ────────────
  final ImagePicker _picker = ImagePicker();
  final List<PendingAttachment> _pending = [];
  static const int _maxVideoBytes = 100 * 1024 * 1024; // 100 MB

  /// A transient pick error (oversize/cancelled-failure) the composer can show.
  String? attachError;

  @override
  List<PendingAttachment> get attachments => _pending;

  @override
  Future<void> pickCameraPhoto() => _addImage(ImageSource.camera);

  @override
  Future<void> pickGalleryPhoto() => _addImage(ImageSource.gallery);

  Future<void> _addImage(ImageSource src) async {
    attachError = null;
    try {
      final x = await _picker.pickImage(
          source: src, maxWidth: 2048, imageQuality: 85);
      if (x == null) return; // cancelled
      final bytes = await x.readAsBytes();
      _pending.add(PendingAttachment(name: x.name, bytes: bytes, isImage: true));
      notifyListeners();
    } catch (_) {
      attachError = 'Couldn’t add that photo.';
      notifyListeners();
    }
  }

  @override
  Future<void> pickVideo() async {
    attachError = null;
    try {
      final x = await _picker.pickVideo(source: ImageSource.gallery);
      if (x == null) return; // cancelled
      // Check the file size BEFORE reading it into memory (a multi-GB video
      // would OOM the app otherwise).
      final fileLen = await File(x.path).length();
      if (fileLen > _maxVideoBytes) {
        attachError = 'That video is too large (max 100 MB).';
        notifyListeners();
        return;
      }
      final bytes = await x.readAsBytes();
      Uint8List? poster;
      try {
        poster = await VideoThumbnail.thumbnailData(
            video: x.path,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 1024,
            quality: 70);
      } catch (_) {
        poster = null; // poster is best-effort; the file still uploads
      }
      _pending.add(PendingAttachment(
          name: x.name, bytes: bytes, isVideo: true, posterBytes: poster));
      notifyListeners();
    } catch (_) {
      attachError = 'Couldn’t add that video.';
      notifyListeners();
    }
  }

  @override
  Future<void> pickFiles() async {
    attachError = null;
    try {
      final res =
          await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
      if (res == null) return; // cancelled
      for (final f in res.files) {
        final data = f.bytes;
        if (data == null) continue;
        _pending.add(PendingAttachment(
            name: f.name, bytes: data, isImage: _looksImage(f.name)));
      }
      notifyListeners();
    } catch (_) {
      attachError = 'Couldn’t add that file.';
      notifyListeners();
    }
  }

  @override
  void removeAttachment(PendingAttachment a) {
    _pending.remove(a);
    notifyListeners();
  }

  bool _looksImage(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.heic');
  }


  /// An open clarify question from the agent ({question, choices}). The UI shows
  /// the question + choice chips; answering posts to /api/clarify/respond so the
  /// blocked turn resumes (otherwise it just hangs on "thinking").
  Map<String, dynamic>? pendingClarify;

  // Live usage from `metering` events (tokens / cost), shown subtly.
  int? inputTokens;
  int? outputTokens;
  double? estimatedCost;

  bool get hasSession => sessionId != null && sessionId!.isNotEmpty;
  bool get isEmpty => messages.isEmpty && !historyLoading;

  // ── Sessions list ─────────────────────────────────────────────
  /// Reload the sessions list. [quiet] skips the loading-spinner toggle and
  /// swallows errors — used by background refreshes (sync signal, tab focus,
  /// the visible-tab poll) so they never flash a spinner or stomp the error bar.
  Future<void> loadSessions({bool quiet = false}) async {
    if (!quiet) {
      sessionsLoading = true;
      notifyListeners();
    }
    try {
      final raw = await _sessions.list();
      if (_disposed) return;
      sessions = raw
          .map((m) => ChatSessionSummary.fromJson(m))
          .where((s) => !s.archived && s.id.isNotEmpty)
          .toList()
        ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
    } catch (e) {
      if (!quiet) error = 'Could not load chats: $e';
    } finally {
      if (!quiet) sessionsLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  // ── Live refresh (sync bus, tab focus, visible-tab poll) ──────
  /// A session changed elsewhere (a voice turn was persisted). Refresh the list
  /// quietly, and silently re-hydrate the open thread if it's the one that
  /// changed and we're not mid-stream.
  void _onSessionChanged(String? changedId) {
    if (_disposed) return;
    loadSessions(quiet: true);
    if (!streaming &&
        changedId != null &&
        changedId.isNotEmpty &&
        changedId == sessionId) {
      refreshActiveQuietly();
    }
  }

  /// Called when the chat tab becomes visible (or the app resumes): pull the
  /// latest list + open thread so anything added while we were away shows up.
  Future<void> refreshOnFocus() async {
    if (_disposed) return;
    await loadSessions(quiet: true);
    await refreshActiveQuietly();
  }

  /// Re-fetch the open thread and re-hydrate it without the open/clear flash.
  /// No-op while streaming, loading, or sessionless (don't clobber a live turn).
  Future<void> refreshActiveQuietly() async {
    final id = sessionId;
    if (_disposed || id == null || id.isEmpty || streaming || historyLoading) {
      return;
    }
    try {
      final data = await _sessions.get(id);
      if (_disposed || id != sessionId || streaming) return; // changed mid-fetch
      final session = (data?['session'] as Map?) ?? data;
      final title = (session?['title'] ?? '').toString().trim();
      if (title.isNotEmpty) sessionTitle = title;
      final rawMessages = (session?['messages'] as List?) ?? const [];
      _hydrateHistory(rawMessages);
      notifyListeners();
    } catch (_) {/* keep the current view on any error */}
  }

  /// Poll the sessions LIST (cheap; previews + ordering) while the chat tab is
  /// visible, so it stays live. The open thread is refreshed on focus and on
  /// sync signals — not polled — to avoid scroll/flicker mid-read.
  void setListPolling(bool on) {
    if (on) {
      if (_listPoll != null) return;
      _listPoll = Timer.periodic(const Duration(seconds: 6), (_) {
        if (!streaming) loadSessions(quiet: true);
      });
    } else {
      _listPoll?.cancel();
      _listPoll = null;
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
  Future<void> send(String text, {bool forceServer = false}) async {
    final trimmed = text.trim();
    // A typed reply while a clarify is open answers it (the turn is still
    // streaming/blocked, so don't start a new one). Leave any pending
    // attachments queued for the next real send.
    if (pendingClarify != null) {
      await respondClarify(trimmed);
      return;
    }
    final pending = List<PendingAttachment>.of(_pending);
    if (trimmed.isEmpty && pending.isEmpty) return; // nothing to send
    if (streaming) return;
    error = null;
    attachError = null;
    _pending.clear();

    messages.add(ChatMessage.user(trimmed,
        attachments: pending.map((a) => a.name).toList(),
        attachmentThumbs: pending
            .map((a) => a.isImage ? a.bytes : (a.isVideo ? a.posterBytes : null))
            .toList()));
    final assistant = ChatMessage(role: 'assistant', streaming: true);
    messages.add(assistant);
    _live = assistant;
    _turnStartedAt = DateTime.now();
    streaming = true;
    notifyListeners();

    try {
      // On-device first: if the local layer fully handles the turn, we never
      // hit the server. Any miss/escalation/error falls through transparently.
      // [forceServer] (the "Try on server" retry) skips the local layer.
      // Attachments always go to the server (the on-device layer can't take them).
      if (!forceServer &&
          pending.isEmpty &&
          LocalAiSettings.instance.enabledForChat &&
          await _tryLocal(trimmed, assistant)) {
        return;
      }

      final id = await _ensureSession();
      final uploaded = await uploadChatAttachments(
          pending, (name, bytes) => _chat.uploadFile(id, bytes, name));
      final start = await _chat.startMessage(
        sessionId: id,
        text: trimmed,
        model: ModelSelection.instance.modelFor(VoiceSurface.chat),
        provider: ModelSelection.instance.providerFor(VoiceSurface.chat),
        attachments: uploaded.isEmpty ? null : uploaded,
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

  /// Re-ask the prompt that produced [localReply] on the SERVER, bypassing the
  /// on-device layer. Appends a fresh server turn (the local reply stays above so
  /// you can compare). No-op while a turn is already streaming.
  void retryOnServer(ChatMessage localReply) {
    if (streaming) return;
    final i = messages.indexOf(localReply);
    if (i <= 0) return;
    // The prompt is the nearest preceding user turn.
    String? userText;
    for (var j = i - 1; j >= 0; j--) {
      if (messages[j].isUser) {
        userText = messages[j].plainText;
        break;
      }
    }
    if (userText == null || userText.trim().isEmpty) return;
    unawaited(send(userText, forceServer: true));
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
          // If Stop tore the stream down mid-generation, [_finishLive] already
          // ran (with cancelled:true) — don't re-finalize or persist a partial.
          if (!streaming) return true;
          // Apple FM doesn't report token usage — estimate (~4 chars/token) so
          // the status line is complete for on-device too.
          final persona = OnDeviceAi.instance.persona;
          assistant.inputTokens = ((text.length + persona.length) / 4).ceil();
          assistant.outputTokens = (assistant.plainText.length / 4).ceil();
          _finishLive();
          unawaited(_persistLocal(text, assistant.plainText));
          return true;

        case ToolCall(:final name, :final args, :final requiresConfirm, :final confirmation):
          // Outward/destructive actions defer to the server's approval flow.
          if (requiresConfirm) return false;
          final InvokeResult res = await app.runner.run(name, args);
          // open_app can return without throwing yet not launch — iOS has no URL
          // scheme for that app (e.g. a bank app). Don't fabricate "Opening X":
          // escalate so the server agent can try a known scheme or answer
          // honestly. The assistant message is still pristine here.
          if (localToolMissed(name, res)) return false;
          final tool = ToolInvocation(name: name, args: args);
          assistant.startTool(tool);
          notifyListeners();
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

  /// Answer the agent's open clarify question so the blocked turn resumes.
  Future<void> respondClarify(String answer) async {
    final a = answer.trim();
    if (a.isEmpty) return;
    final sid = sessionId;
    pendingClarify = null;
    notifyListeners();
    if (sid == null) return;
    try {
      await _chat.api
          .postJson('/api/clarify/respond', {'session_id': sid, 'response': a});
    } catch (e) {
      debugPrint('[chat] clarify respond failed: $e');
    }
  }

  /// Persist a completed on-device turn into the server session so it shows on
  /// the web + other devices. Best-effort.
  ///
  /// On-device image generation embeds the result as a multi-MB base64 data-URL
  /// markdown image. We strip those to a short placeholder before persisting so
  /// the session JSON stays small — the in-memory message the user sees this
  /// session keeps the full image (only the SERVER copy is trimmed).
  Future<void> _persistLocal(String userText, String assistantText) async {
    try {
      final sid = await _ensureSession();
      await _sessions.appendLocalTurn(sid,
          user: userText, assistant: _stripPersistedImages(assistantText));
    } catch (_) {}
  }

  /// Replace inline base64 data-URL images (`![alt](data:image/…;base64,…)`)
  /// with a short `[generated image]` placeholder so megabytes of base64 never
  /// get written to the server session.
  static final RegExp _dataImageRe =
      RegExp(r'!\[[^\]]*\]\(data:image/[^)]+\)');
  static String _stripPersistedImages(String text) =>
      text.replaceAll(_dataImageRe, '[generated image]');

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
    void done() {
      if (!completer.isCompleted) completer.complete();
    }

    // Cancel any prior local generation before starting a new one.
    unawaited(_localSub?.cancel());
    _localDone = completer;
    late final StreamSubscription<String> sub;
    sub = OnDeviceAi.instance.generate(req).listen(
      (t) {
        // Ignore late tokens delivered after a Stop tore the stream down (or
        // after this subscription was superseded) — nothing should append to
        // the message once cancelled.
        if (_localSub != sub) return;
        assistant.appendToken(t);
        notifyListeners();
      },
      onError: (_) => done(),
      onDone: done,
      cancelOnError: true,
    );
    _localSub = sub;
    await completer.future;
    // If we were cancelled (the subscription is no longer current), bail
    // without backfilling — the cancelled turn keeps whatever it had.
    if (_localSub != sub) return;
    _localSub = null;
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
      case 'clarify':
        final q = (ev['question'] ?? '').toString();
        final choices = (ev['choices_offered'] is List)
            ? (ev['choices_offered'] as List).map((c) => c.toString()).toList()
            : <String>[];
        if (q.isNotEmpty) {
          pendingClarify = {'question': q, 'choices': choices};
          notifyListeners();
        }
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
    // The metering event nests usage inconsistently (top-level, `usage`,
    // `data`, or `data.usage`), so dig through all of them for each field.
    int? digInt(String key) {
      for (final m in [
        ev,
        ev['usage'],
        ev['data'],
        (ev['data'] is Map) ? (ev['data'] as Map)['usage'] : null,
      ]) {
        if (m is Map && m[key] != null) {
          final v = _asInt(m[key]);
          if (v != null) return v;
        }
      }
      return null;
    }

    final inp = digInt('input_tokens');
    final out = digInt('output_tokens');
    final usage = (ev['usage'] is Map)
        ? Map<String, dynamic>.from(ev['usage'] as Map)
        : ev;
    final cost = _asDouble(usage['estimated_cost']);
    if (inp != null) _live?.inputTokens = inp;
    if (out != null) _live?.outputTokens = out;
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
      if (_turnStartedAt != null) {
        live.durationMs =
            DateTime.now().difference(_turnStartedAt!).inMilliseconds;
      }
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
    // Cancel the on-device generation too. Cancelling triggers OnDeviceAi's
    // controller.onCancel → native cancel(requestId), actually stopping the
    // model. Null it FIRST so the listen-guard drops any late tokens, then
    // complete the awaiting [_streamLocalReply] so its send() returns.
    final localSub = _localSub;
    _localSub = null;
    localSub?.cancel();
    if (_localDone != null && !_localDone!.isCompleted) _localDone!.complete();
    _localDone = null;
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
    _disposed = true;
    _sub?.cancel();
    _syncSub?.cancel();
    _listPoll?.cancel();
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

/// Upload each pending attachment (and a video's first-frame poster as a second
/// vision image) via [upload], returning the result maps for `/api/chat/start`'s
/// `attachments[]`. A failed upload is skipped so the rest + the text still send.
/// Top-level + dependency-injected so it's unit-testable without the controller.
Future<List<Map<String, dynamic>>> uploadChatAttachments(
  List<PendingAttachment> pending,
  Future<Map<String, dynamic>> Function(String name, List<int> bytes) upload,
) async {
  final out = <Map<String, dynamic>>[];
  for (final a in pending) {
    try {
      final up = await upload(a.name, a.bytes);
      if (up.isNotEmpty) out.add(up);
      final poster = a.posterBytes;
      if (poster != null && poster.isNotEmpty) {
        final p = await upload('${a.name}.poster.jpg', poster);
        if (p.isNotEmpty) out.add(p);
      }
    } catch (_) {
      // skip this attachment; keep the others + the message text
    }
  }
  return out;
}
