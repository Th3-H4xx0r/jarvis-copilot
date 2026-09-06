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
    var tags: [String]

    init(id: String, body: String, source: String = "", createdAt: String = "",
         score: Double? = nil, namespace: String = "", tags: [String] = []) {
        self.id = id
        self.body = body
        self.source = source
        self.createdAt = createdAt
        self.score = score
        self.namespace = namespace
        self.tags = tags
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        body = MoreJSON.text(json["body"])
        source = MoreJSON.text(json["source"])
        createdAt = MoreJSON.text(json["created_at"])
        score = MoreJSON.double(json["score"])
        namespace = MoreJSON.text(json["namespace"])
        tags = MoreJSON.stringList(json["tags"])
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
    var ts: String
    var kind: String
    var title: String
    var body: String
    var status: String
    var dedupKey: String

    init(id: String, ts: String = "", kind: String = "", title: String = "",
         body: String = "", status: String = "", dedupKey: String = "") {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
        self.dedupKey = dedupKey
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        ts = MoreJSON.text(json["ts"])
        kind = MoreJSON.text(json["kind"])
        title = MoreJSON.text(json["title"])
        body = MoreJSON.text(json["body"])
        status = MoreJSON.text(json["status"])
        dedupKey = MoreJSON.text(json["dedup_key"])
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
    var status: JarvisMemoryStatus = .init()

    init() {}

    init(stats: JSONObject, status statusJSON: JSONObject, reflections: [MemoryReflection]) {
        count = JarvisMemoryParse.asInt(stats["count"])
        namespaces = JarvisMemoryParse.namespaces(stats)
        statsUnavailable = MoreJSON.isFalse(stats["available"])
        statusUnavailable = MoreJSON.isFalse(statusJSON["available"])
        errorText = MoreJSON.nonEmpty(stats["error"]) ?? MoreJSON.nonEmpty(statusJSON["error"])
        self.reflections = reflections
        status = JarvisMemoryStatus(json: statusJSON)
    }

    /// The store is usable only if neither stats nor status reported a failure.
    var available: Bool { !statsUnavailable && !statusUnavailable }

    /// A human-readable reason the store is unavailable, if the backend gave one.
    var unavailableMessage: String? {
        guard let errorText, !errorText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return errorText
    }
}

/// `/api/jarvis-memory/status` — the provider/embedder/ollama snapshot.
struct JarvisMemoryStatus: Equatable, Sendable {
    var embedModel = ""
    var embedDim = 0
    var extractModel = ""
    var ollamaRunning = false
    var ollamaURL = ""
    var count = 0

    init() {}

    init(json: JSONObject) {
        embedModel = MoreJSON.text(json["embed_model"])
        embedDim = MoreJSON.int(json["embed_dim"])
        extractModel = MoreJSON.text(json["extract_model"])
        ollamaRunning = MoreJSON.isTrue(json["ollama_running"])
        ollamaURL = MoreJSON.text(json["ollama_url"])
        count = MoreJSON.int(json["count"])
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
            out.append(MemoryNamespace(namespace: name, count: asInt(m["count"])))
        }
        return out
    }

    /// Search-result entries. Real shape is `{entries:[…]}`; `{results:[…]}` and
    /// a bare list are also accepted.
    static func entries(_ data: Any?) -> [MemoryEntry] {
        let raw: Any?
        if let object = data as? JSONObject {
            raw = object["entries"] ?? object["results"]
        } else {
            raw = data
        }
        return MoreJSON.mapList(raw).map(MemoryEntry.init(json:))
    }

    static func reflections(_ data: Any?) -> [MemoryReflection] {
        let raw = (data as? JSONObject)?["reflections"] ?? data
        return MoreJSON.mapList(raw).map(MemoryReflection.init(json:))
    }

    /// JSON number / numeric string / null → Int (0 on failure).
    static func asInt(_ value: Any?) -> Int {
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard let d = MoreJSON.double(value), d.isFinite else { return 0 }
        return Int(d)
    }
}
