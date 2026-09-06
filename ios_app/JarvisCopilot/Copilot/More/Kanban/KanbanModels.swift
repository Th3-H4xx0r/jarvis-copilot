import Foundation

/// One task on the board. The bridge sends a lot of optional metadata, so the
/// decoded `raw` dictionary is kept for anything the UI needs but this struct
/// doesn't name.
struct KanbanTask: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var status: String
    var assignee: String
    var priority: String
    var due: String
    var commentCount: Int
    var raw: JSONObject

    static func == (l: KanbanTask, r: KanbanTask) -> Bool {
        l.id == r.id && l.title == r.title && l.body == r.body && l.status == r.status
            && l.assignee == r.assignee && l.priority == r.priority && l.due == r.due
            && l.commentCount == r.commentCount
    }

    init(json: JSONObject) {
        id = Kanban.taskID(json)
        title = MoreJSON.text(json["title"])
        body = MoreJSON.text(json["body"] ?? json["description"])
        status = Kanban.taskColumn(json)
        assignee = MoreJSON.text(json["assignee"]).trimmingCharacters(in: .whitespaces)
        priority = MoreJSON.text(json["priority"])
        due = MoreJSON.text(json["due"] ?? json["due_date"]).trimmingCharacters(in: .whitespaces)
        commentCount = MoreJSON.int(json["comment_count"])
        raw = json
    }

    var isRunning: Bool { status == "running" }
    var isBlocked: Bool { status == "blocked" }

    /// "alice · P2 · due Friday" — the tile's meta line.
    var metaLine: String {
        var parts: [String] = []
        if !assignee.isEmpty { parts.append(assignee) }
        if !priority.isEmpty && priority != "0" { parts.append("P\(priority)") }
        if !due.isEmpty { parts.append("due \(due)") }
        return parts.joined(separator: " · ")
    }
}

/// Board metadata from `/api/kanban/boards`.
struct KanbanBoard: Identifiable, Equatable, Sendable {
    var slug: String
    var name: String
    var description: String
    var isCurrent: Bool
    var total: Int?
    var id: String { slug }

    var displayName: String { name.isEmpty ? slug : name }
    /// "12 task(s)" subtitle for the switcher, or nil when the count is absent.
    var totalLabel: String? { total.map { "\($0) task(s)" } }

    init(slug: String, name: String = "", description: String = "",
         isCurrent: Bool = false, total: Int? = nil) {
        self.slug = slug
        self.name = name
        self.description = description
        self.isCurrent = isCurrent
        self.total = total
    }

    init(json: JSONObject) {
        slug = MoreJSON.text(json["slug"])
        name = MoreJSON.text(json["name"] ?? json["title"])
        description = MoreJSON.text(json["description"])
        isCurrent = MoreJSON.isTrue(json["is_current"])
        total = json["total"].flatMap { $0 is NSNull ? nil : MoreJSON.int($0) }
    }
}

/// One comment on a task (`GET /api/kanban/tasks/:id` → `comments[]`).
struct KanbanComment: Identifiable, Equatable, Sendable {
    var id: String
    var author: String
    var body: String
    var ts: String

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        author = MoreJSON.text(json["author"] ?? json["who"])
        body = MoreJSON.text(json["body"] ?? json["text"])
        ts = MoreJSON.text(json["ts"] ?? json["created_at"])
    }
}

/// Full task detail — the board payload carries only counts, so the detail sheet
/// has to fetch this for `comments[]` / `links{}` / `events[]` / `runs[]`.
struct KanbanTaskDetail: Equatable, Sendable {
    var task: KanbanTask?
    var comments: [KanbanComment] = []
    var links: JSONObject = [:]
    var events: [JSONObject] = []
    var runs: [JSONObject] = []

    static func == (l: KanbanTaskDetail, r: KanbanTaskDetail) -> Bool {
        l.task == r.task && l.comments == r.comments
            && l.events.count == r.events.count && l.runs.count == r.runs.count
    }

    init() {}

    init(json: JSONObject) {
        if let t = json["task"] as? JSONObject { task = KanbanTask(json: t) }
        comments = MoreJSON.mapList(json["comments"]).map(KanbanComment.init(json:))
        links = MoreJSON.map(json["links"])
        events = MoreJSON.mapList(json["events"])
        runs = MoreJSON.mapList(json["runs"])
    }
}

/// Pure helpers shared by the board, the filter bar and the tests.
enum Kanban {
    /// The fixed column order the mobile board surfaces — a subset of the
    /// bridge's `BOARD_COLUMNS`.
    static let columns = ["triage", "todo", "ready", "running", "blocked", "done"]

    /// Columns you may create into / move to. The bridge answers HTTP 400 for a
    /// direct status write to `running` — entering it is the dispatcher's job.
    static let manualColumns = columns.filter { $0 != "running" }

    /// A task's stable id. The bridge serialises it as `id`; `task_id` (event
    /// rows and some legacy shapes) is tolerated.
    static func taskID(_ task: JSONObject) -> String {
        MoreJSON.text(task["id"] ?? task["task_id"])
    }

    /// A task's column. The bridge keys it off `status`; a `column` alias is
    /// tolerated. Falls back to `todo` so a malformed row still buckets.
    static func taskColumn(_ task: JSONObject) -> String {
        let raw = MoreJSON.text(task["column"] ?? task["status"])
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "todo" : raw
    }

    /// Group a flat task list by column.
    ///
    /// Every column in `columns` gets an entry (empty when nothing matches), in
    /// the order given. Tasks whose column isn't in the set are dropped — the
    /// board only renders the fixed columns.
    static func groupTasksByColumn(_ tasks: [Any],
                                   _ columns: [String]) -> [String: [KanbanTask]] {
        var out: [String: [KanbanTask]] = [:]
        for column in columns { out[column] = [] }
        for raw in tasks {
            guard let m = raw as? JSONObject else { continue }
            let column = taskColumn(m)
            guard out[column] != nil else { continue }
            out[column]?.append(KanbanTask(json: m))
        }
        return out
    }

    /// Flatten the bridge's `board['columns']` (a list of `{name, tasks}`) into
    /// one flat list. A bare `board['tasks']` list is tolerated.
    static func flattenTasks(_ board: JSONObject) -> [JSONObject] {
        var out: [JSONObject] = []
        if let columns = board["columns"] as? [Any] {
            for column in columns {
                guard let c = column as? JSONObject else { continue }
                out.append(contentsOf: MoreJSON.mapList(c["tasks"]))
            }
            return out
        }
        return MoreJSON.mapList(board["tasks"])
    }

    /// Slugify a board title the way the bridge expects (lowercase, hyphenated,
    /// alnum only). The server re-normalises anyway; this just has to be accepted.
    static func slugify(_ title: String) -> String {
        var out = ""
        var pendingSeparator = false
        for ch in title.trimmingCharacters(in: .whitespaces).lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingSeparator && !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(ch)
            } else {
                pendingSeparator = true
            }
        }
        return out.isEmpty ? "board" : out
    }

    static func columnLabel(_ column: String) -> String {
        guard let first = column.first else { return column }
        return first.uppercased() + column.dropFirst()
    }

    static func columnIcon(_ column: String) -> String {
        switch column {
        case "triage": return "tray"
        case "todo": return "circle"
        case "ready": return "play.circle"
        case "running": return "arrow.triangle.2.circlepath"
        case "blocked": return "nosign"
        case "done": return "checkmark.circle"
        default: return "tag"
        }
    }

    static func columnTone(_ column: String) -> MoreTone {
        switch column {
        case "done": return .success
        case "blocked": return .danger
        case "running": return .cyan
        case "ready": return .accent
        case "triage": return .accentAlt
        default: return .muted
        }
    }

    /// The dispatcher's result line: `{spawned|claimed|count}` may be a number
    /// or a list, and may be absent entirely.
    static func dispatchMessage(_ result: JSONObject) -> String {
        let raw = result["spawned"] ?? result["claimed"] ?? result["count"]
        var n: Int?
        if let list = raw as? [Any] {
            n = list.count
        } else if let value = raw, !(value is NSNull), let d = MoreJSON.double(value) {
            n = Int(d)
        }
        guard let n else { return "Dispatcher ran" }
        if n == 0 { return "Dispatcher ran — no ready tasks to start" }
        return "Dispatcher ran — \(n) worker\(n == 1 ? "" : "s") started"
    }
}
