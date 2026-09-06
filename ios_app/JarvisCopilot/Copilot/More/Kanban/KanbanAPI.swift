import Foundation

/// Native client for the WebUI's Kanban bridge (`/api/kanban/*` in
/// `webui/api/kanban_bridge.py`) — the same surface the web panel drives, so the
/// mobile board cannot drift from it.
///
/// Endpoint quirks worth knowing (verified against the bridge):
///   * the board is grouped server-side into `board['columns']`, a list of
///     `{name, tasks: [...]}`; a task's column lives in its `status` field;
///   * moving a task is `PATCH /tasks/:id` with `{status: <col>}` (NOT
///     `column`) — `patchTask` normalises a `column` key to `status`;
///   * there is NO `DELETE /api/kanban/tasks/:id` route, so "delete" is
///     `PATCH {status: 'archived'}` (which is also what the web does);
///   * `createBoard` requires a `slug` — the bridge derives nothing from the
///     title, so we slugify client-side and send `name` + `slug`.
struct KanbanAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    private func boardQuery(_ slug: String?) -> [String: String] {
        guard let slug, !slug.isEmpty else { return [:] }
        return ["board": slug]
    }

    // MARK: Boards

    func boards() async throws -> [KanbanBoard] {
        let body = try await api.get("/api/kanban/boards").object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "boards")).map(KanbanBoard.init(json:))
    }

    /// `slug` omitted ⇒ the server's active board. The bridge returns the board
    /// map at the top level (columns/assignees are direct keys), not nested under
    /// `board`; both shapes are tolerated.
    func board(slug: String? = nil) async throws -> JSONObject {
        let body = try await api.get("/api/kanban/board", query: boardQuery(slug)).object()
        if let nested = body["board"] as? JSONObject { return nested }
        return body
    }

    /// `{by_status, by_assignee}` — passed through untouched.
    func stats(slug: String? = nil) async throws -> JSONObject {
        try await api.get("/api/kanban/stats", query: boardQuery(slug)).object()
    }

    func assignees(slug: String? = nil) async throws -> [String] {
        let body = try await api.get("/api/kanban/assignees", query: boardQuery(slug)).object()
        return MoreJSON.stringList(MoreJSON.envelopeList(body, "assignees"))
    }

    /// The bridge requires a `slug`; derive one from the title, send the title
    /// as `name`, and switch to the new board.
    func createBoard(title: String, description: String) async throws -> JSONObject {
        try await api.post("/api/kanban/boards", json: [
            "slug": Kanban.slugify(title),
            "name": title,
            "description": description,
            "switch": true,
        ]).object()
    }

    func switchBoard(_ slug: String) async throws -> JSONObject {
        try await api.post("/api/kanban/boards/\(slug)/switch", json: JSONObject()).object()
    }

    /// Update display metadata (name/description/icon/color/archived). The slug
    /// is immutable.
    func renameBoard(_ slug: String, body: JSONObject) async throws -> JSONObject {
        try await api.patch("/api/kanban/boards/\(slug)", json: body).object()
    }

    /// Archive (soft-remove) a board. (`delete=1` would hard-delete; we archive.)
    func archiveBoard(_ slug: String) async throws -> JSONObject {
        try await api.delete("/api/kanban/boards/\(slug)", query: ["archive": "true"]).object()
    }

    // MARK: Tasks

    func taskDetail(_ id: String, board: String? = nil) async throws -> KanbanTaskDetail {
        let body = try await api.get("/api/kanban/tasks/\(id)", query: boardQuery(board)).object()
        return KanbanTaskDetail(json: body)
    }

    /// The worker log text. The bridge returns `{content, …}`; older shapes used
    /// `log`. Both are tolerated; "" when neither is present.
    func taskLog(_ id: String, board: String? = nil) async throws -> String {
        let response = try await api.get("/api/kanban/tasks/\(id)/log", query: boardQuery(board))
        guard let body = try? response.object() else { return response.text }
        if let value = body["log"] ?? body["content"], !(value is NSNull) {
            return MoreJSON.text(value)
        }
        return ""
    }

    func createTask(_ body: JSONObject, board: String? = nil) async throws -> JSONObject {
        try await api.post("/api/kanban/tasks", json: body, query: boardQuery(board)).object()
    }

    /// Pass `{status: 'done'}` (or the `column` alias, normalised to `status`) to
    /// MOVE a task; other fields edit in place.
    func patchTask(_ id: String, _ body: JSONObject, board: String? = nil) async throws -> JSONObject {
        var normalised = body
        if normalised["column"] != nil, normalised["status"] == nil {
            normalised["status"] = normalised.removeValue(forKey: "column")
        } else {
            normalised.removeValue(forKey: "column")
        }
        return try await api.patch("/api/kanban/tasks/\(id)", json: normalised,
                                   query: boardQuery(board)).object()
    }

    /// Delete a task = ARCHIVE it (matches the web). The bridge has no
    /// DELETE-task route, and archiving removes it from every visible column —
    /// which is what "delete" means in the UI.
    func deleteTask(_ id: String, board: String? = nil) async throws -> JSONObject {
        try await patchTask(id, ["status": "archived"], board: board)
    }

    /// The bridge reads the comment text from `body` (not `text`); both are sent.
    func comment(_ id: String, text: String, board: String? = nil) async throws -> JSONObject {
        try await api.post("/api/kanban/tasks/\(id)/comments",
                           json: ["body": text, "text": text],
                           query: boardQuery(board)).object()
    }

    func block(_ id: String, reason: String, board: String? = nil) async throws -> JSONObject {
        try await api.post("/api/kanban/tasks/\(id)/block",
                           json: ["reason": reason],
                           query: boardQuery(board)).object()
    }

    func unblock(_ id: String, board: String? = nil) async throws -> JSONObject {
        try await api.post("/api/kanban/tasks/\(id)/unblock",
                           json: JSONObject(),
                           query: boardQuery(board)).object()
    }

    /// Run the dispatcher once: claim ready+assigned tasks and spawn workers.
    /// `dryRun` previews without spawning.
    func dispatch(slug: String? = nil, dryRun: Bool = false, max: Int = 8) async throws -> JSONObject {
        var query = ["dry_run": dryRun ? "true" : "false", "max": "\(max)"]
        if let slug, !slug.isEmpty { query["board"] = slug }
        return try await api.post("/api/kanban/dispatch", json: JSONObject(), query: query).object()
    }

    // MARK: Live updates

    /// SSE: each event carries an `event` key plus the decoded payload.
    func events() -> AsyncThrowingStream<SSEEvent, Error> {
        api.streamSSE("/api/kanban/events/stream")
    }
}
