import Foundation

/// Which half of a project's code memory to read. "Handoffs" in the UI is
/// `sessions` on the wire.
enum CodeMemoryKind: String, CaseIterable, Identifiable, Sendable {
    case knowledge
    case sessions

    var id: String { rawValue }
    var label: String { self == .sessions ? "Handoffs" : "Knowledge" }
    /// Fallback entry type when a row has neither content nor `entry_type`.
    var defaultEntryType: String { self == .sessions ? "handoff" : "note" }
}

/// One repo the agent has stored code memory for. The server returns a MAP keyed
/// by sanitised slug, so the key — never an inner field — is the identity.
struct CodeMemoryProject: Identifiable, Equatable, Sendable {
    var slug: String
    var name: String
    var root: String
    var remote: String
    var firstSeen: String
    var lastSeen: String
    var knowledgeCount: Int
    var sessionsCount: Int

    var id: String { slug }
    /// Display name, falling back to the slug and then to "(unnamed)".
    var title: String {
        if !name.isEmpty { return name }
        return slug.isEmpty ? "(unnamed)" : slug
    }

    init(slug: String, name: String = "", root: String = "", remote: String = "",
         firstSeen: String = "", lastSeen: String = "",
         knowledgeCount: Int = 0, sessionsCount: Int = 0) {
        self.slug = slug
        self.name = name
        self.root = root
        self.remote = remote
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.knowledgeCount = knowledgeCount
        self.sessionsCount = sessionsCount
    }

    init(slug: String, json: JSONObject) {
        self.slug = slug
        name = MoreJSON.text(json["name"])
        root = MoreJSON.text(json["root"])
        remote = MoreJSON.text(json["remote"])
        firstSeen = MoreJSON.text(json["first_seen"])
        lastSeen = MoreJSON.text(json["last_seen"])
        knowledgeCount = MoreJSON.int(json["knowledge_count"] ?? json["knowledge"])
        sessionsCount = MoreJSON.int(json["sessions_count"] ?? json["sessions"])
    }

    func lastSeenLabel(now: Date = Date()) -> String {
        RelativeTime.format(lastSeen, now: now)
    }

    /// Does this project match the overview's search box?
    func matches(_ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if f.isEmpty { return true }
        return name.lowercased().contains(f) || slug.lowercased().contains(f)
    }
}

/// One knowledge/handoff record. `content` is present on the list endpoint;
/// server-side search returns compact rows carrying `first_line` instead.
struct CodeMemoryEntry: Identifiable, Equatable, Sendable {
    var id: String
    var ts: String
    var entryType: String
    var content: String
    var firstLine: String
    var slug: String
    var kind: String

    init(id: String, ts: String = "", entryType: String = "", content: String = "",
         firstLine: String = "", slug: String = "", kind: String = "") {
        self.id = id
        self.ts = ts
        self.entryType = entryType
        self.content = content
        self.firstLine = firstLine
        self.slug = slug
        self.kind = kind
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        ts = MoreJSON.text(json["ts"])
        entryType = MoreJSON.text(json["entry_type"])
        content = MoreJSON.text(json["content"])
        firstLine = MoreJSON.text(json["first_line"])
        slug = MoreJSON.text(json["slug"])
        kind = MoreJSON.text(json["kind"])
    }

    /// List title: the first line of the body (or the compact `first_line`),
    /// falling back to the entry type.
    func title(kind fallback: CodeMemoryKind) -> String {
        let text = (content.isEmpty ? firstLine : content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.split(separator: "\n", maxSplits: 1,
                               omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty { return first }
        return entryType.isEmpty ? fallback.defaultEntryType : entryType
    }

    func tsLabel(now: Date = Date()) -> String { RelativeTime.format(ts, now: now) }
}

/// Global counts from `/api/code-memory/stats` — a flat body, no wrapper.
struct CodeMemoryStats: Equatable, Sendable {
    var projects: Int?
    var knowledge: Int?
    var sessions: Int?
    var lastActivity: String?

    init() {}

    init(json: JSONObject) {
        // nil (not 0) when the key is absent or null, so the overview knows to
        // derive the number from the project list instead of showing a false zero.
        func count(_ key: String) -> Int? {
            guard let value = json[key], !(value is NSNull) else { return nil }
            return MoreJSON.int(value)
        }
        projects = count("projects")
        knowledge = count("knowledge")
        sessions = count("sessions")
        lastActivity = MoreJSON.nonEmpty(json["last_activity"])
    }
}

/// The overview screen's combined payload: `/stats` plus `/projects`. Stats is
/// best-effort — when it fails the totals are derived from the projects list so
/// the header is never blank.
struct CodeMemoryOverview: Equatable, Sendable {
    var stats = CodeMemoryStats()
    var projects: [CodeMemoryProject] = []

    var totalProjects: Int { stats.projects ?? projects.count }
    var totalKnowledge: Int { stats.knowledge ?? projects.reduce(0) { $0 + $1.knowledgeCount } }
    var totalHandoffs: Int { stats.sessions ?? projects.reduce(0) { $0 + $1.sessionsCount } }

    /// "Last active 5m ago" tail, or "" when there is no timestamp.
    func lastActivityLabel(now: Date = Date()) -> String {
        guard let raw = stats.lastActivity else { return "" }
        return RelativeTime.format(raw, now: now)
    }
}

enum CodeMemoryParse {
    /// Normalise the projects payload to a list where each row carries its slug.
    ///
    /// The server returns a MAP keyed by sanitised slug; a bare list (each item
    /// already carrying `slug`) and an empty/null body are also tolerated.
    static func projects(_ raw: Any?) -> [CodeMemoryProject] {
        if let map = raw as? JSONObject {
            return map.map { key, value in
                // The map key is the authoritative slug — never let a stray
                // inner field win.
                CodeMemoryProject(slug: key, json: (value as? JSONObject) ?? [:])
            }
        }
        if let list = raw as? [Any] {
            return list.compactMap { item in
                guard let m = item as? JSONObject else { return nil }
                return CodeMemoryProject(slug: MoreJSON.text(m["slug"]), json: m)
            }
        }
        return []
    }

    /// Pull `entries` out of any `{entries: […]}` envelope; a bare list works too.
    static func entries(_ data: Any?) -> [CodeMemoryEntry] {
        let raw = (data as? JSONObject)?["entries"] ?? data
        return MoreJSON.mapList(raw).map(CodeMemoryEntry.init(json:))
    }
}
