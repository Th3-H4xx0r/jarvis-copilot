import 'dart:async';
import 'dart:io'
    show HandshakeException, HttpException, SocketException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/api_client.dart';

/// One streaming chat turn. Mirrors the Web UI contract:
/// POST /api/chat/start to create a run, then GET /api/chat/stream
/// with the returned stream_id.
///
/// The frames we care about:
///   { event: "delta",    text: "..." }    — token chunk
///   { event: "tool",     name, args }     — tool call
///   { event: "thinking", text: "..." }    — collapsible
///   { event: "done",     usage: {...} }   — end of turn
///
/// Unknown events are surfaced verbatim so future server-side additions
/// don't break us.
class ChatApi {
  ChatApi(this.api);
  final ApiClient api;

  /// Whether this server collapses start+stream into one response (plan 5.1).
  /// null = not probed yet; false = probed and unsupported (older server), so
  /// we stop paying the probe. Process-wide: one server per app session.
  static bool? _streamingStartSupported;

  @visibleForTesting
  static set streamingStartSupported(bool? v) => _streamingStartSupported = v;

  Stream<Map<String, dynamic>> sendMessage({
    required String sessionId,
    required String text,
    String? model,
    String? provider,
    String? workspace,
    String? profile,
    List<Map<String, dynamic>>? attachments,
  }) async* {
    // Fast path: POST /api/chat/start?stream=1 answers with the SSE stream
    // directly, saving a whole tunnel round-trip per turn (plan 5.1). Feature-
    // detected — an older server answers with plain JSON and we fall through
    // to the classic two-step flow below.
    if (_streamingStartSupported != false) {
      // Declared OUTSIDE the try so the catch clauses below can see it: a
      // fallback is only safe before any event has reached the caller
      // (otherwise it would double-submit the turn).
      var streamed = false;
      try {
        final stream = api.postSseOrJson(
          '/api/chat/start',
          _startBody(
            sessionId: sessionId,
            text: text,
            model: model,
            provider: provider,
            workspace: workspace,
            profile: profile,
            attachments: attachments,
          ),
          query: {'stream': '1'},
        );
        await for (final ev in stream) {
          if (ev[r'$sse'] == false) {
            // Not a stream — the server answered with the ordinary start JSON.
            _streamingStartSupported = false;
            final body = Map<String, dynamic>.from(
                (ev['body'] as Map?) ?? const <String, dynamic>{});
            yield {'event': 'started', ...body};
            final sid = (body['stream_id'] ?? '').toString();
            if (sid.isEmpty) {
              throw StateError('chat/start did not return stream_id');
            }
            yield* streamEvents(sid);
            return;
          }
          if (!streamed) {
            streamed = true;
            _streamingStartSupported = true;
          }
          yield ev;
        }
        if (streamed) return;
        // A stream that produced nothing: treat as unsupported and retry the
        // classic path rather than leaving the turn silent.
        _streamingStartSupported = false;
      } on StateError catch (e) {
        // 404/405 from a server without ?stream=1 → remember and fall back.
        debugPrint('[chat] streaming start unavailable: $e');
        _streamingStartSupported = false;
      } on SocketException catch (e) {
        // Connect-level failures (refused, DNS, dropped mid-handshake) are
        // treated the same as "unsupported": fall back to the classic path
        // rather than surfacing the turn as failed — but ONLY before any SSE
        // event has reached the caller. Once streaming has actually started,
        // a fallback would double-submit the turn, so it rethrows instead.
        if (streamed) rethrow;
        debugPrint('[chat] streaming start failed before first event ($e)');
        _streamingStartSupported = false;
      } on TimeoutException catch (e) {
        if (streamed) rethrow;
        debugPrint('[chat] streaming start failed before first event ($e)');
        _streamingStartSupported = false;
      } on HandshakeException catch (e) {
        if (streamed) rethrow;
        debugPrint('[chat] streaming start failed before first event ($e)');
        _streamingStartSupported = false;
      } on HttpException catch (e) {
        if (streamed) rethrow;
        debugPrint('[chat] streaming start failed before first event ($e)');
        _streamingStartSupported = false;
      }
    }

    final start = await startMessage(
      sessionId: sessionId,
      text: text,
      model: model,
      provider: provider,
      workspace: workspace,
      profile: profile,
      attachments: attachments,
    );
    yield {'event': 'started', ...start};
    final streamId = (start['stream_id'] ?? '').toString();
    if (streamId.isEmpty) {
      throw StateError('chat/start did not return stream_id');
    }
    yield* streamEvents(streamId);
  }

  Future<Map<String, dynamic>> startMessage({
    required String sessionId,
    required String text,
    String? model,
    String? provider,
    String? workspace,
    String? profile,
    List<Map<String, dynamic>>? attachments,
  }) async {
    final resp = await api.postJson(
      '/api/chat/start',
      _startBody(
        sessionId: sessionId,
        text: text,
        model: model,
        provider: provider,
        workspace: workspace,
        profile: profile,
        attachments: attachments,
      ),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Map<String, dynamic> _startBody({
    required String sessionId,
    required String text,
    String? model,
    String? provider,
    String? workspace,
    String? profile,
    List<Map<String, dynamic>>? attachments,
  }) =>
      {
        'session_id': sessionId,
        'message': text,
        if (model != null && model.isNotEmpty) 'model': model,
        if (provider != null && provider.isNotEmpty) 'model_provider': provider,
        if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
        if (profile != null && profile.isNotEmpty) 'profile': profile,
        if (attachments != null && attachments.isNotEmpty)
          'attachments': attachments,
      };

  /// Upload one composer attachment to `/api/upload` (multipart). Returns the
  /// full result map `{filename, path, mime, size, is_image}` — the shape
  /// `/api/chat/start` expects in its `attachments[]`.
  Future<Map<String, dynamic>> uploadFile(
      String sessionId, List<int> bytes, String filename) async {
    final form = FormData.fromMap({
      'session_id': sessionId,
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await api.postMultipart('/api/upload', form,
        timeout: const Duration(seconds: 60));
    return Map<String, dynamic>.from((resp.data as Map?) ?? const {});
  }

  Stream<Map<String, dynamic>> streamEvents(String streamId) {
    return api.streamSse('/api/chat/stream', query: {'stream_id': streamId});
  }

  Future<Map<String, dynamic>> cancel(String streamId) async {
    final resp = await api.get('/api/chat/cancel', query: {'stream_id': streamId});
    return Map<String, dynamic>.from(resp.data as Map);
  }
}
