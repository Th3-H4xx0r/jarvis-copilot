import 'dart:convert';

import '../services/api_client.dart';

/// Read-only mirror of the web "Todos" panel: the active chat session's current
/// todo list. There is NO todos API — the web (panels.js `loadTodos`) derives
/// the list from the session's message history by scanning newest-first for a
/// `role: 'tool'` message whose JSON `content` carries a non-empty `todos`
/// array of `{id, content, status}` items. We do the same here.
class TodosApi {
  TodosApi(this.api);
  final ApiClient api;

  /// Resolve the active session and return its current todo list (or `[]`).
  ///
  /// The mobile app has no app-level "active session" singleton (the chat
  /// screen owns a per-page [ChatController]), so we mirror what the user sees
  /// as their open chat: the most-recently-updated session. If there are no
  /// sessions, returns `[]`.
  Future<List<Map<String, dynamic>>> currentSession() async {
    final id = await _activeSessionId();
    if (id == null || id.isEmpty) return const [];
    final messages = await _sessionMessages(id);
    return extractTodos(messages);
  }

  /// The most-recently-updated session's id, or null when there are none.
  /// Mirrors ChatController.openInitial(): sort by updated_at desc, take first.
  Future<String?> _activeSessionId() async {
    final resp = await api.get('/api/sessions');
    final data = resp.data;
    final s = data is Map ? data['sessions'] : data;
    final raw = s is List ? s : const [];
    final rows = raw.whereType<Map>().toList();
    if (rows.isEmpty) return null;
    int updatedOf(Map m) => _asInt(m['updated_at'] ?? m['last_message_at']) ?? 0;
    rows.sort((a, b) => updatedOf(b).compareTo(updatedOf(a)));
    for (final m in rows) {
      final id = (m['session_id'] ?? m['id'] ?? '').toString();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  /// Fetch a session's messages via GET /api/session?session_id=…&messages=1.
  /// The body is `{session: {…, messages: [...]}}`; tolerate a bare `messages`.
  Future<List<dynamic>> _sessionMessages(String sessionId) async {
    final resp = await api.get('/api/session', query: {
      'session_id': sessionId,
      'messages': '1',
      'resolve_model': '0',
    });
    final data = resp.data;
    if (data is! Map) return const [];
    final session = data['session'] is Map ? data['session'] as Map : data;
    final msgs = session['messages'];
    return msgs is List ? msgs : const [];
  }
}

/// Pure, dependency-free helper: scan [messages] newest-first for the first
/// `role: 'tool'` message whose `content` (JSON string or already-decoded map)
/// holds a non-empty `todos` list, and return that list. Returns `[]` if none.
///
/// Each returned todo is `{id, content, status}` with status in
/// pending | in_progress | completed | cancelled. Top-level + side-effect free
/// so it's unit-testable without the network.
List<Map<String, dynamic>> extractTodos(List<dynamic> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m is! Map) continue;
    if ((m['role'] ?? '') != 'tool') continue;
    final todos = _todosFromContent(m['content']);
    if (todos.isNotEmpty) return todos;
  }
  return const [];
}

/// Parse a tool message's `content` and pull out a non-empty `todos` array.
/// `content` may be a JSON string, an already-decoded Map, or anything else
/// (ignored). Each todo is normalised to a `Map<String, dynamic>`.
List<Map<String, dynamic>> _todosFromContent(Object? content) {
  Object? decoded = content;
  if (content is String) {
    final s = content.trim();
    if (s.isEmpty) return const [];
    try {
      decoded = jsonDecode(s);
    } catch (_) {
      return const [];
    }
  }
  if (decoded is! Map) return const [];
  final raw = decoded['todos'];
  if (raw is! List || raw.isEmpty) return const [];
  return raw
      .whereType<Map>()
      .map((t) => Map<String, dynamic>.from(t))
      .toList(growable: false);
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}
