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
