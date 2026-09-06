import Foundation

/// One workspace: an absolute filesystem path plus a friendly display name.
/// The server stores workspaces as objects, so we model them the same way
/// rather than as bare path strings.
struct Workspace: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    /// The path is the identity — the display name is editable.
    var id: String { path }

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    /// Parse one entry. Tolerates a bare string (the path, named by its last
    /// segment) or a `{path, name}` object.
    init(any raw: Any?) {
        if let s = raw as? String {
            path = s
            name = Workspace.basename(s)
            return
        }
        if let m = raw as? JSONObject {
            let p = MoreJSON.text(m["path"])
            let n = MoreJSON.text(m["name"])
            path = p
            name = n.isEmpty ? Workspace.basename(p) : n
            return
        }
        path = ""
        name = ""
    }

    /// Last path segment, with any trailing slashes trimmed first.
    static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else {
            return trimmed.isEmpty ? path : trimmed
        }
        let base = String(trimmed[trimmed.index(after: slash)...])
        return base.isEmpty ? trimmed : base
    }
}

/// The parsed `GET /api/workspaces` payload: the ordered list plus the path of
/// the most-recently-used workspace (for the "last used" badge).
struct WorkspaceList: Equatable, Sendable {
    var workspaces: [Workspace]
    var last: String

    init(workspaces: [Workspace] = [], last: String = "") {
        self.workspaces = workspaces
        self.last = last
    }
}

/// Pure parser for `GET /api/workspaces`, kept out of the API struct so it can
/// be tested without a transport.
///
/// Accepts the documented `{workspaces: [...], last: "..."}` shape, tolerates a
/// missing/empty/non-object input, and copes with entries that are either
/// `{path, name}` objects or bare path strings. Entries with an empty path are
/// dropped — they can't be acted on.
func parseWorkspaceList(_ data: Any?) -> WorkspaceList {
    guard let object = data as? JSONObject else { return WorkspaceList() }
    let workspaces: [Workspace]
    if let raw = object["workspaces"] as? [Any] {
        workspaces = raw.map(Workspace.init(any:)).filter { !$0.path.isEmpty }
    } else {
        workspaces = []
    }
    return WorkspaceList(workspaces: workspaces, last: MoreJSON.text(object["last"]))
}
