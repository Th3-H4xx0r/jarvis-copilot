import Foundation

/// One namespace bucket from `/api/jarvis-memory/stats`.
struct MemoryNamespace: Identifiable, Equatable, Sendable {
    var namespace: String
    var count: Int
    var id: String { namespace }
}

/// One semantic-store row from `/api/jarvis-memory/search`.
///
/// Field names are the REAL backend ones — do NOT "tidy" them: the text lives in
/// `body` (not `text`) and `id` is a string.
struct MemoryEntry: Identifiable, Equatable, Sendable {
    var id: String
    var body: String
    var source: String
    var createdAt: String
    var score: Double?
    var namespace: String

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        body = MoreJSON.text(json["body"])
        source = MoreJSON.text(json["source"])
        createdAt = MoreJSON.text(json["created_at"])
        score = MoreJSON.double(json["score"])
        namespace = MoreJSON.text(json["namespace"])
    }

    /// Relative "created" line for the card, or "" when there is no timestamp.
    func createdLabel(now: Date = Date()) -> String {
        RelativeTime.format(createdAt, now: now)
    }
}

/// A proactive insight card from `/api/jarvis-memory/reflections`. This is a raw
/// sqlite row, so `id` is an INTEGER (the dismiss endpoint needs it numeric).
struct MemoryReflection: Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var title: String
    var body: String

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        kind = MoreJSON.text(json["kind"])
        title = MoreJSON.text(json["title"])
        body = MoreJSON.text(json["body"])
    }
}

/// The whole-screen payload, loaded in one shot so the view can decide
/// availability vs. content from a single value.
struct JarvisMemoryData: Equatable, Sendable {
    /// Total entries in the store, from `/stats`.
    var count: Int = 0
    var namespaces: [MemoryNamespace] = []
    /// Set only when the endpoint answered a literal `available: false`; a
    /// missing key must not read as unavailable.
    var statsUnavailable = false
    var statusUnavailable = false
    var errorText: String?
    var reflections: [MemoryReflection] = []

    init() {}

    init(stats: JSONObject, status statusJSON: JSONObject, reflections: [MemoryReflection]) {
        count = MoreJSON.int(stats["count"])
        namespaces = JarvisMemoryParse.namespaces(stats)
        statsUnavailable = MoreJSON.isFalse(stats["available"])
        statusUnavailable = MoreJSON.isFalse(statusJSON["available"])
        errorText = MoreJSON.nonEmpty(stats["error"]) ?? MoreJSON.nonEmpty(statusJSON["error"])
        self.reflections = reflections
    }

    /// The store is usable only if neither stats nor status reported a failure.
    var available: Bool { !statsUnavailable && !statusUnavailable }

    /// A human-readable reason the store is unavailable, if the backend gave one.
    var unavailableMessage: String? {
        guard let errorText, !errorText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return errorText
    }
}

/// Parsers for the fail-soft `/api/jarvis-memory/*` payloads. Every endpoint can
/// answer `{available:false, error:…}` when the store isn't initialised, so
/// nothing here may assume a key exists.
enum JarvisMemoryParse {
    /// Namespaces out of a `/stats` payload. Accepts the real shape
    /// `{namespaces:[{namespace,count}]}`, a bare list of those objects, and is
    /// safe on null / missing / wrong types.
    static func namespaces(_ data: Any?) -> [MemoryNamespace] {
        let raw: Any? = (data as? JSONObject)?["namespaces"] ?? data
        guard let items = raw as? [Any] else { return [] }
        var out: [MemoryNamespace] = []
        for item in items {
            guard let m = item as? JSONObject else { continue }
            let name = MoreJSON.text(m["namespace"] ?? m["name"])
            if name.isEmpty { continue }
            out.append(MemoryNamespace(namespace: name, count: MoreJSON.int(m["count"])))
        }
        return out
    }

    /// Search-result entries: `{entries:[…]}`, or a bare list.
    static func entries(_ data: Any?) -> [MemoryEntry] {
        let raw = (data as? JSONObject)?["entries"] ?? data
        return MoreJSON.mapList(raw).map(MemoryEntry.init(json:))
    }

    static func reflections(_ data: Any?) -> [MemoryReflection] {
        let raw = (data as? JSONObject)?["reflections"] ?? data
        return MoreJSON.mapList(raw).map(MemoryReflection.init(json:))
    }
}

// MARK: - Memory map

/// `/api/jarvis-memory/map-settings`: which model reads chats, iMessage and Live
/// to map memories to dates, people and places. `agent` uses the iMessage card's
/// wire shape; nil = Same as Default. `label` is the server's name for what it
/// resolved to.
struct MemoryMapSettings: Decodable, Equatable {
    var agent: AgentChoice?
    var label: String

    init(agent: AgentChoice?, label: String) {
        self.agent = agent
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(IMessageMemoryAgent.self, forKey: .agent)?.choice
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case agent, label }
}

/// What one cleanup step reports while it runs.
struct MemoryCleanupProgress: Equatable {
    var step: String
    var done: Int
    var total: Int

    /// The server's step keys, in plain English.
    static let stepNames = [
        "starting": "Starting", "backup": "Backing up", "live": "Rewriting Live",
        "stamps": "Fixing times", "duplicates": "Merging duplicates", "map": "Mapping memories",
    ]

    /// "Merging duplicates · 3/10", or just the step before it knows the total.
    /// A step the app doesn't know yet shows as the server named it.
    var line: String {
        let name = step.isEmpty ? "Working" : (Self.stepNames[step] ?? step)
        return total > 0 ? "\(name) · \(done)/\(total)" : name
    }

    var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
}

/// The report's buckets, in the order the card lists them.
enum MemoryCleanupKind: String, CaseIterable {
    case merged
    case hiddenTrivial = "hidden_trivial"
    case superseded
    case liveRewritten = "live_rewritten"
    case restamped
    case enriched
    case failed

    var label: String {
        switch self {
        case .merged: return "Merged duplicates"
        case .hiddenTrivial: return "Hidden trivia"
        case .superseded: return "Marked out of date"
        case .liveRewritten: return "Live rewritten"
        case .restamped: return "Times fixed"
        case .enriched: return "Mapped"
        case .failed: return "Couldn't map"
        }
    }

    /// Merged and trivial rows were hidden, so they can come back. Out-of-date
    /// ones are still there, just marked past.
    var restorable: Bool { self == .merged || self == .hiddenTrivial }
}

struct MemoryCleanupCount: Identifiable, Equatable {
    var kind: MemoryCleanupKind
    var value: Int
    var id: String { kind.rawValue }
    var label: String { kind.label }
}

struct MemoryCleanupExample: Identifiable, Equatable {
    var id: String
    var body: String
}

struct MemoryCleanupExamples: Identifiable, Equatable {
    var kind: MemoryCleanupKind
    var items: [MemoryCleanupExample]
    var id: String { kind.rawValue }
}

/// The last finished run, from `cleanup_report.json`.
struct MemoryCleanupReport: Equatable {
    var startedAt: Date?
    var finishedAt: Date?
    var backup: String
    /// Every bucket but `failed`, which only shows when something failed.
    var counts: [MemoryCleanupCount]
    /// Only the example lists that have rows.
    var examples: [MemoryCleanupExamples]

    init(json: JSONObject) {
        startedAt = RelativeTime.parse(json["started_at"])
        finishedAt = RelativeTime.parse(json["finished_at"])
        backup = MoreJSON.text(json["backup"])
        let counts = MoreJSON.map(json["counts"])
        self.counts = MemoryCleanupKind.allCases.compactMap { kind in
            let value = MoreJSON.int(counts[kind.rawValue])
            if kind == .failed && value == 0 { return nil }
            return MemoryCleanupCount(kind: kind, value: value)
        }
        let examples = MoreJSON.map(json["examples"])
        self.examples = [MemoryCleanupKind.merged, .hiddenTrivial, .superseded].compactMap { kind in
            let items = MoreJSON.mapList(examples[kind.rawValue]).map {
                MemoryCleanupExample(id: MoreJSON.text($0["id"]), body: MoreJSON.text($0["body"]))
            }.filter { !$0.id.isEmpty }
            return items.isEmpty ? nil : MemoryCleanupExamples(kind: kind, items: items)
        }
    }
}

/// `/api/jarvis-memory/cleanup/status`.
struct MemoryCleanupStatus: Equatable {
    /// True for a run started anywhere — this phone, the web, or the server's
    /// own shell backfill.
    var running: Bool
    /// A Stop was asked for and the run is winding down.
    var stopping: Bool
    var progress: MemoryCleanupProgress?
    var report: MemoryCleanupReport?
    var error: String?

    var canStop: Bool { running && !stopping }
    var stopTitle: String { stopping ? "Stopping…" : "Stop" }
    /// After a finished run it is a re-run, still behind the confirmation.
    var runTitle: String { report == nil ? "Run cleanup" : "Run again" }

    init(json: JSONObject) {
        running = MoreJSON.isTrue(json["running"])
        stopping = MoreJSON.isTrue(json["stopping"])
        if let p = json["progress"] as? JSONObject {
            progress = MemoryCleanupProgress(step: MoreJSON.text(p["step"]),
                                             done: MoreJSON.int(p["done"]),
                                             total: MoreJSON.int(p["total"]))
        }
        if let r = json["report"] as? JSONObject { report = MemoryCleanupReport(json: r) }
        error = MoreJSON.nonEmpty(json["error"])
    }
}
