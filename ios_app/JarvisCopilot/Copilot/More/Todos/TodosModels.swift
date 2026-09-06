import Foundation

/// One row of the active chat session's todo list. `status` stays a raw string
/// because the server (really: the agent's TodoWrite tool) owns the vocabulary —
/// pending | in_progress | completed | cancelled — and an unknown value must
/// still render rather than crash.
struct TodoItem: Identifiable, Equatable, Sendable {
    var id: String
    var content: String
    var status: String

    init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        content = MoreJSON.text(json["content"])
        let s = MoreJSON.text(json["status"])
        status = s.isEmpty ? "pending" : s
    }

    var isFinished: Bool { status == "completed" || status == "cancelled" }

    /// Sort weight so active work surfaces first: in-progress, pending,
    /// completed, cancelled. Unknown statuses sort with pending.
    var rank: Int {
        switch status {
        case "in_progress": return 0
        case "pending": return 1
        case "completed": return 2
        case "cancelled": return 3
        default: return 1
        }
    }

    var style: TodoStatusStyle { TodoStatusStyle.of(status) }
}

/// Visual treatment per status — mirrors panels.js `loadTodos`. Icons are SF
/// Symbol names and the colour is a `MoreTone` slot, so the view owns the theme.
struct TodoStatusStyle: Equatable, Sendable {
    var iconName: String
    var tone: MoreTone
    var label: String
    var strikethrough: Bool = false
    var spin: Bool = false

    static func of(_ status: String) -> TodoStatusStyle {
        switch status {
        case "completed":
            return .init(iconName: "checkmark.circle.fill", tone: .success,
                         label: "COMPLETED", strikethrough: true)
        case "in_progress":
            return .init(iconName: "arrow.triangle.2.circlepath", tone: .primaryBlue,
                         label: "IN PROGRESS", spin: true)
        case "cancelled":
            return .init(iconName: "xmark.circle.fill", tone: .muted,
                         label: "CANCELLED", strikethrough: true)
        default:
            return .init(iconName: "circle", tone: .muted, label: "PENDING")
        }
    }
}

/// Pure, dependency-free extraction of the todo list from a session's message
/// history. There is NO todos API — the web panel (panels.js `loadTodos`) scans
/// the messages newest-first for the first `role: "tool"` message whose JSON
/// `content` carries a non-empty `todos` array, and we do exactly the same.
enum TodosParser {
    static func extractTodos(_ messages: [Any]) -> [TodoItem] {
        for message in messages.reversed() {
            guard let m = message as? JSONObject else { continue }
            guard MoreJSON.text(m["role"]) == "tool" else { continue }
            let todos = todos(fromContent: m["content"])
            if !todos.isEmpty { return todos }
        }
        return []
    }

    /// `content` may be a JSON string, an already-decoded object, or junk.
    /// An empty `todos` array counts as "no list" so the scan keeps going.
    static func todos(fromContent content: Any?) -> [TodoItem] {
        var decoded: Any? = content
        if let s = content as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return [] }
            decoded = parsed
        }
        guard let object = decoded as? JSONObject else { return [] }
        let rows = MoreJSON.mapList(object["todos"])
        guard !rows.isEmpty else { return [] }
        return rows.map(TodoItem.init(json:))
    }
}
