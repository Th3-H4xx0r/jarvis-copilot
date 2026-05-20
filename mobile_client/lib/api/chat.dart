import 'dart:async';

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

  Stream<Map<String, dynamic>> sendMessage({
    required String sessionId,
    required String text,
    String? model,
    String? provider,
    String? workspace,
    String? profile,
  }) async* {
    final start = await startMessage(
      sessionId: sessionId,
      text: text,
      model: model,
      provider: provider,
      workspace: workspace,
      profile: profile,
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
  }) async {
    final resp = await api.postJson('/api/chat/start', {
      'session_id': sessionId,
      'message': text,
      if (model != null && model.isNotEmpty) 'model': model,
      if (provider != null && provider.isNotEmpty) 'model_provider': provider,
      if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
      if (profile != null && profile.isNotEmpty) 'profile': profile,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Stream<Map<String, dynamic>> streamEvents(String streamId) {
    return api.streamSse('/api/chat/stream', query: {'stream_id': streamId});
  }

  Future<Map<String, dynamic>> cancel(String streamId) async {
    final resp = await api.get('/api/chat/cancel', query: {'stream_id': streamId});
    return Map<String, dynamic>.from(resp.data as Map);
  }
}
