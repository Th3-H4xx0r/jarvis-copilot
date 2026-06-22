import '../services/api_client.dart';

/// A single workspace entry: an absolute filesystem [path] plus a friendly
/// display [name]. The server stores workspaces as objects, so we model them
/// the same way rather than as bare path strings.
class Workspace {
  const Workspace({required this.path, required this.name});

  final String path;
  final String name;

  /// Parse one entry from the server. Tolerates a bare string (treated as a
  /// path with the last segment as its name) or a `{path, name}` map.
  factory Workspace.fromAny(dynamic raw) {
    if (raw is String) {
      return Workspace(path: raw, name: _basename(raw));
    }
    if (raw is Map) {
      final path = (raw['path'] ?? '').toString();
      final name = (raw['name'] ?? '').toString();
      return Workspace(path: path, name: name.isEmpty ? _basename(path) : name);
    }
    return const Workspace(path: '', name: '');
  }

  static String _basename(String path) {
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    final idx = trimmed.lastIndexOf('/');
    final base = idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
    return base.isEmpty ? trimmed : base;
  }
}

/// The parsed result of `GET /api/workspaces`: the ordered list of workspaces
/// plus the path of the most-recently-used one (for the "last used" badge).
class WorkspaceList {
  const WorkspaceList({required this.workspaces, required this.last});

  final List<Workspace> workspaces;
  final String last;
}

/// Pure, side-effect-free parser for the `GET /api/workspaces` payload. Kept
/// out of [WorkspacesApi] so it can be unit-tested without an HTTP client.
///
/// Accepts the documented `{workspaces: [...], last: "..."}` shape, tolerates
/// a missing/empty/non-map input (returns an empty list + empty last), and
/// copes with workspace entries that are either `{path, name}` maps or bare
/// path strings.
WorkspaceList parseWorkspaceList(dynamic data) {
  if (data is! Map) {
    return const WorkspaceList(workspaces: [], last: '');
  }
  final rawList = data['workspaces'];
  final workspaces = rawList is List
      ? rawList
          .map(Workspace.fromAny)
          .where((w) => w.path.isNotEmpty)
          .toList(growable: false)
      : const <Workspace>[];
  final last = (data['last'] ?? '').toString();
  return WorkspaceList(workspaces: workspaces, last: last);
}

/// Talks to the server's workspace endpoints (the same ones the webui's
/// Workspaces panel drives). Workspaces are an ordered list of absolute paths,
/// each with a friendly name; one may be flagged "last used".
class WorkspacesApi {
  WorkspacesApi(this.api);
  final ApiClient api;

  /// `GET /api/workspaces` → `{workspaces: [...], last: "..."}`.
  Future<WorkspaceList> list() async {
    final resp = await api.get('/api/workspaces');
    return parseWorkspaceList(resp.data);
  }

  /// `GET /api/workspaces/suggest?prefix=...` → list of candidate path strings.
  Future<List<String>> suggest(String prefix) async {
    final resp =
        await api.get('/api/workspaces/suggest', query: {'prefix': prefix});
    final data = resp.data;
    final raw = data is Map ? data['suggestions'] : null;
    return raw is List
        ? raw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
  }

  /// `POST /api/workspaces/add` `{path}` — adds (and, server-side, creates if
  /// needed) the workspace at [path].
  Future<void> add(String path) async {
    await api.postJson('/api/workspaces/add', {'path': path});
  }

  /// `POST /api/workspaces/remove` `{path}`.
  Future<void> remove(String path) async {
    await api.postJson('/api/workspaces/remove', {'path': path});
  }

  /// `POST /api/workspaces/rename` `{path, name}` — renames the workspace's
  /// friendly display [name] (the path itself is the identity and is fixed).
  Future<void> rename(String path, String name) async {
    await api.postJson('/api/workspaces/rename', {'path': path, 'name': name});
  }

  /// `POST /api/workspaces/reorder` `{paths}` — rewrites the workspace order to
  /// match the given ordered list of paths.
  Future<void> reorder(List<String> paths) async {
    await api.postJson('/api/workspaces/reorder', {'paths': paths});
  }
}
