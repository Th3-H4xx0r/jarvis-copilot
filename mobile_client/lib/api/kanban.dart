import '../main.dart' as app;
import '../services/api_client.dart';

/// Native client for the WebUI's Kanban bridge (`/api/kanban/*` in
/// `webui/api/kanban_bridge.py`). The bridge is the same surface the web
/// kanban panel drives, so the mobile board cannot drift from it.
///
/// Endpoint quirks worth knowing (verified against the bridge):
///  * The board is grouped server-side into `board['columns']` — a list of
///    `{name, tasks: [...]}`. A task's column lives in its `status` field.
///  * Moving a task is `PATCH /tasks/:id` with `{status: <col>}` (NOT
///    `column`). [patchTask] normalises a `column` key to `status` so callers
///    can speak either dialect.
///  * There is NO `DELETE /api/kanban/tasks/:id` route in the bridge — the
///    only DELETE routes are `/boards/:slug` and `/links`. [deleteTask] still
///    issues the DELETE first (in case a deployment adds it), then falls back
///    to `PATCH {status: 'archived'}`, which the bridge does support.
///  * `createBoard` requires a `slug`; the bridge derives nothing from the
///    title, so we slugify the title client-side and send `name`+`slug`.
class KanbanApi {
  KanbanApi(this.api);
  final ApiClient api;

  Map<String, String> _boardQuery(String? slug) =>
      {if (slug != null && slug.isNotEmpty) 'board': slug};

  /// GET /api/kanban/boards → list of board metadata maps
  /// (`{slug, name, is_current, counts, total, ...}`).
  Future<List<Map<String, dynamic>>> boards() async {
    final resp = await api.get('/api/kanban/boards');
    final data = resp.data;
    final raw = data is Map ? (data['boards'] as List?) : (data as List?);
    return (raw ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  /// GET /api/kanban/board → the board map (`{columns: [...], tenants,
  /// assignees, ...}`). [slug] omitted ⇒ the active board.
  Future<Map<String, dynamic>> board({String? slug}) async {
    final resp = await api.get('/api/kanban/board', query: _boardQuery(slug));
    final data = resp.data;
    final b = data is Map ? data['board'] : null;
    // The bridge returns the board map at the top level (columns/assignees
    // are direct keys), not nested under `board`. Tolerate both shapes.
    if (b is Map) return Map<String, dynamic>.from(b);
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  /// GET /api/kanban/stats → `{by_status, by_assignee}` (shape is passed
  /// through untouched).
  Future<Map<String, dynamic>> stats({String? slug}) async {
    final resp = await api.get('/api/kanban/stats', query: _boardQuery(slug));
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// GET /api/kanban/assignees → `data['assignees']` (list of strings).
  Future<List<String>> assignees({String? slug}) async {
    final resp =
        await api.get('/api/kanban/assignees', query: _boardQuery(slug));
    final data = resp.data;
    final raw = data is Map ? (data['assignees'] as List?) : (data as List?);
    return (raw ?? const [])
        .map((e) => '$e')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// Run the dispatcher once: claim ready+assigned tasks and spawn workers.
  /// POST /api/kanban/dispatch?dry_run=&max=. Returns the result map (e.g.
  /// `{spawned, claimed, reclaimed, ...}`); `dryRun` previews without spawning.
  Future<Map<String, dynamic>> dispatch(
      {String? slug, bool dryRun = false, int max = 8}) async {
    final q = <String, String>{'dry_run': '$dryRun', 'max': '$max'};
    if (slug != null && slug.isNotEmpty) q['board'] = slug;
    final qs = q.entries.map((e) => '${e.key}=${e.value}').join('&');
    final resp = await api.postJson('/api/kanban/dispatch?$qs', const {});
    final data = resp.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// GET /api/kanban/tasks/:id/log → the worker log text. The bridge returns
  /// `{content, ...}`; older shapes used `log`. Tolerate both, return ''.
  Future<String> taskLog(String id, {String? board}) async {
    final resp = await api.get(
      '/api/kanban/tasks/$id/log',
      query: _boardQuery(board),
    );
    final data = resp.data;
    if (data is Map) {
      final v = data['log'] ?? data['content'];
      if (v != null) return '$v';
    }
    if (data is String) return data;
    return '';
  }

  /// Full task detail (comments, links, events, runs) — the board payload only
  /// carries counts, so the detail sheet must fetch this.
  Future<Map<String, dynamic>> taskDetail(String id, {String? board}) async {
    final resp = await api.get('/api/kanban/tasks/$id',
        query: board != null ? {'board': board} : null);
    final d = resp.data;
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  /// POST /api/kanban/tasks → `{task: {...}}`.
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> body,
      {String? board}) async {
    final resp = await api.postJson(
      _withBoard('/api/kanban/tasks', board),
      body,
    );
    return _asMap(resp.data);
  }

  /// PATCH /api/kanban/tasks/:id. Pass `{status: 'done'}` (or the `column`
  /// alias, which is normalised to `status`) to MOVE a task between columns;
  /// other fields (title/body/assignee/priority) edit in place.
  Future<Map<String, dynamic>> patchTask(String id, Map<String, dynamic> body,
      {String? board}) async {
    final normalised = Map<String, dynamic>.from(body);
    // The bridge keys the column off `status`; let callers say `column`.
    if (normalised.containsKey('column') && !normalised.containsKey('status')) {
      normalised['status'] = normalised.remove('column');
    } else {
      normalised.remove('column');
    }
    final resp = await api.patchJson(
      _withBoard('/api/kanban/tasks/$id', board),
      normalised,
    );
    return _asMap(resp.data);
  }

  /// POST /api/kanban/tasks/:id/comments. The bridge reads the comment text
  /// from `body` (not `text`); we send both for resilience.
  Future<Map<String, dynamic>> comment(String id, String text,
      {String? board}) async {
    final resp = await api.postJson(
      _withBoard('/api/kanban/tasks/$id/comments', board),
      {'body': text, 'text': text},
    );
    return _asMap(resp.data);
  }

  /// POST /api/kanban/tasks/:id/block — the bridge reads `reason`.
  Future<Map<String, dynamic>> block(String id, String reason,
      {String? board}) async {
    final resp = await api.postJson(
      _withBoard('/api/kanban/tasks/$id/block', board),
      {'reason': reason},
    );
    return _asMap(resp.data);
  }

  /// POST /api/kanban/tasks/:id/unblock.
  Future<Map<String, dynamic>> unblock(String id, {String? board}) async {
    final resp = await api.postJson(
      _withBoard('/api/kanban/tasks/$id/unblock', board),
      const {},
    );
    return _asMap(resp.data);
  }

  /// Delete a task = ARCHIVE it (matches the web). The bridge has no
  /// DELETE-task route (only /boards/:slug and /links), and permanent removal
  /// requires the task to be archived first anyway; archiving removes it from
  /// every visible column, which is what "delete" means in the UI. We go
  /// straight to `PATCH {status: 'archived'}` — attempting the missing DELETE
  /// route just 500s.
  Future<Map<String, dynamic>> deleteTask(String id, {String? board}) async {
    return patchTask(id, {'status': 'archived'}, board: board);
  }

  /// POST /api/kanban/boards. The bridge requires a `slug`; derive one from
  /// the title and send the title as `name`.
  Future<Map<String, dynamic>> createBoard(String title, String desc) async {
    final resp = await api.postJson('/api/kanban/boards', {
      'slug': kanbanSlugify(title),
      'name': title,
      'description': desc,
      'switch': true,
    });
    return _asMap(resp.data);
  }

  /// POST /api/kanban/boards/:slug/switch — set the active board everywhere.
  Future<Map<String, dynamic>> switchBoard(String slug) async {
    final resp = await api.postJson('/api/kanban/boards/$slug/switch', const {});
    return _asMap(resp.data);
  }

  /// PATCH /api/kanban/boards/:slug — update display metadata
  /// (name/description/icon/color/archived). The slug is immutable.
  Future<Map<String, dynamic>> renameBoard(
      String slug, Map<String, dynamic> body) async {
    final resp = await api.patchJson('/api/kanban/boards/$slug', body);
    return _asMap(resp.data);
  }

  /// DELETE /api/kanban/boards/:slug?archive=true — archive (soft-remove) a
  /// board. (Pass `delete=1` server-side for a hard delete; we archive.)
  Future<Map<String, dynamic>> archiveBoard(String slug) async {
    final resp = await api.deleteJson('/api/kanban/boards/$slug?archive=true');
    return _asMap(resp.data);
  }

  /// SSE: GET /api/kanban/events/stream. Each event map carries an `event`
  /// key plus the decoded payload.
  Stream<Map<String, dynamic>> events() =>
      app.api.streamSse('/api/kanban/events/stream');

  String _withBoard(String path, String? board) =>
      (board == null || board.isEmpty) ? path : '$path?board=$board';

  Map<String, dynamic> _asMap(dynamic data) =>
      data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
}

// ── Pure helpers (unit-tested) ──────────────────────────────────────────

/// The fixed column order shared by the board and the filter bar. Mirrors a
/// subset of the bridge's BOARD_COLUMNS that the mobile board surfaces.
const List<String> kanbanColumns = [
  'triage',
  'todo',
  'ready',
  'running',
  'blocked',
  'done',
];

/// A task's stable id. The bridge serialises it as `id`; tolerate `task_id`
/// (used by event rows and some legacy shapes).
String kanbanTaskId(Map task) {
  final v = task['id'] ?? task['task_id'];
  return v == null ? '' : '$v';
}

/// A task's column. The bridge keys it off `status`; tolerate a `column`
/// alias. Falls back to 'todo' so a malformed row still buckets somewhere.
String kanbanTaskColumn(Map task) {
  final v = task['column'] ?? task['status'];
  final s = v == null ? '' : '$v'.trim();
  return s.isEmpty ? 'todo' : s;
}

/// Group a flat list of task maps by column into `{column: [tasks...]}`.
///
/// Every column in [columns] gets an entry (empty list when no tasks match),
/// in the order given. Tasks whose column is not in [columns] are dropped —
/// the board only renders the fixed set. Pure + side-effect free for testing.
Map<String, List<Map<String, dynamic>>> groupTasksByColumn(
  List tasks,
  List<String> columns,
) {
  final out = <String, List<Map<String, dynamic>>>{
    for (final c in columns) c: <Map<String, dynamic>>[],
  };
  for (final raw in tasks) {
    if (raw is! Map) continue;
    final col = kanbanTaskColumn(raw);
    final bucket = out[col];
    if (bucket != null) bucket.add(Map<String, dynamic>.from(raw));
  }
  return out;
}

/// Flatten the bridge's `board['columns']` (a list of `{name, tasks}`) into a
/// single flat task list. Tolerates a bare `board['tasks']` list too. Pure.
List<Map<String, dynamic>> kanbanFlattenTasks(Map board) {
  final out = <Map<String, dynamic>>[];
  final columns = board['columns'];
  if (columns is List) {
    for (final col in columns) {
      if (col is! Map) continue;
      final colTasks = col['tasks'];
      if (colTasks is List) {
        for (final t in colTasks) {
          if (t is Map) out.add(Map<String, dynamic>.from(t));
        }
      }
    }
    return out;
  }
  final flat = board['tasks'];
  if (flat is List) {
    for (final t in flat) {
      if (t is Map) out.add(Map<String, dynamic>.from(t));
    }
  }
  return out;
}

/// Slugify a board title the way the bridge expects (lowercase, hyphenated,
/// alnum-only). Mirrors `kanban_db._normalize_board_slug` loosely enough that
/// the server accepts it; the server re-normalises anyway.
String kanbanSlugify(String title) {
  final s = title
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'board' : s;
}
