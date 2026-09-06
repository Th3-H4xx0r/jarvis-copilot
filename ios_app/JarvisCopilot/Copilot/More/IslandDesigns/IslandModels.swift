import Foundation

/// Models for the Dynamic Island Designs feature.
///
/// The app does NOT render the layout tree — the widget extension does that from
/// a cached copy — so a design keeps the tree as an opaque `raw` object it can
/// cache and introspect for bindings, while the catalog and selection drive the
/// settings screen and the auto-selection engine.

/// A full custom design: identity plus the opaque layout tree (`raw`).
struct IslandDesign: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var icon: String
    var version: Int
    var raw: JSONObject

    static func == (l: IslandDesign, r: IslandDesign) -> Bool {
        l.id == r.id && l.name == r.name && l.icon == r.icon
            && l.version == r.version && l.contentSignature == r.contentSignature
    }

    init(id: String, name: String, icon: String, version: Int, raw: JSONObject) {
        self.id = id
        self.name = name
        self.icon = icon
        self.version = version
        self.raw = raw
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        let name = MoreJSON.text(json["name"] ?? json["id"])
        self.name = name
        icon = MoreJSON.text(json["icon"])
        version = IslandParse.int(json["version"], default: 1)
        raw = json
    }

    /// The full tree as JSON — what gets cached into the App Group container.
    /// Keys are sorted so the string (and therefore the signature) is stable.
    var jsonString: String { MoreJSON.canonicalJSON(raw) }

    /// A signature of the design's CONTENT (the whole tree), not just its
    /// version. Drives cache-busting and push de-dupe so a layout edit applies
    /// live even when Jarvis forgets to bump `version`.
    var contentSignature: Int { MoreJSON.stableHash(jsonString) }

    /// Offline keyframe timeline `[{at: epochSeconds, data: {...}}]` — the
    /// coordinator overlays the current keyframe's data by the clock.
    var timeline: [JSONObject] { MoreJSON.mapList(raw["timeline"]) }

    /// Pre-scheduled local notifications `[{at, title, body}]` that fire offline.
    var notifications: [JSONObject] { MoreJSON.mapList(raw["notifications"]) }

    /// Offline scheduled jobs `[{at, notify:{title,body?}, action?:{skill,args?}}]`
    /// — generalises `notifications`. Each fires a local notification OFFLINE at
    /// `at`; the optional `action` runs when the user TAPS it.
    var jobs: [JSONObject] { MoreJSON.mapList(raw["jobs"]) }

    /// Unified, normalised scheduled items the offline scheduler consumes:
    /// `notifications` (no action) + `jobs` (notify + optional action), each
    /// `{at, title, body, action?}`. Items missing a usable `at`/`title` are
    /// kept here and filtered by the scheduler.
    var offlineScheduledItems: [JSONObject] {
        var out: [JSONObject] = []
        // Legacy `notifications` are notify-only — tap actions are a jobs-only
        // feature (the schema validates `action` on jobs, not notifications).
        for n in notifications {
            out.append(["at": n["at"] ?? NSNull(),
                        "title": n["title"] ?? NSNull(),
                        "body": n["body"] ?? NSNull()])
        }
        for job in jobs {
            let notify = MoreJSON.map(job["notify"])
            var item: JSONObject = ["at": job["at"] ?? NSNull(),
                                    "title": notify["title"] ?? NSNull(),
                                    "body": notify["body"] ?? NSNull()]
            if let action = job["action"] as? JSONObject { item["action"] = action }
            out.append(item)
        }
        return out
    }
}

/// Catalog metadata + auto-rules for one entry (a custom design OR a built-in
/// `voice` / `coding` mode). Drives the settings list and the auto picker.
struct IslandCatalogEntry: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var icon: String
    var version: Int
    var builtin: Bool
    var enabled: Bool
    var priority: Int
    /// Condition expression (see `IslandBindings.evaluateCondition`); nil = always.
    var conditions: JSONObject?
    /// `{days:[1-7]? (Mon=1…Sun=7), from:"HH:MM", to:"HH:MM"}` or nil = any time.
    var schedule: JSONObject?

    static func == (l: IslandCatalogEntry, r: IslandCatalogEntry) -> Bool {
        l.id == r.id && l.name == r.name && l.icon == r.icon && l.version == r.version
            && l.builtin == r.builtin && l.enabled == r.enabled && l.priority == r.priority
            && MoreJSON.canonicalJSON(l.conditions ?? [:]) == MoreJSON.canonicalJSON(r.conditions ?? [:])
            && MoreJSON.canonicalJSON(l.schedule ?? [:]) == MoreJSON.canonicalJSON(r.schedule ?? [:])
    }

    init(id: String, name: String, icon: String, version: Int, builtin: Bool,
         enabled: Bool, priority: Int,
         conditions: JSONObject? = nil, schedule: JSONObject? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.version = version
        self.builtin = builtin
        self.enabled = enabled
        self.priority = priority
        self.conditions = conditions
        self.schedule = schedule
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        name = MoreJSON.text(json["name"] ?? json["id"])
        icon = MoreJSON.text(json["icon"])
        version = IslandParse.int(json["version"], default: 1)
        builtin = MoreJSON.isTrue(json["builtin"])
        enabled = !MoreJSON.isFalse(json["enabled"])   // default enabled
        priority = IslandParse.int(json["priority"], default: 0)
        conditions = json["conditions"] as? JSONObject
        schedule = json["schedule"] as? JSONObject
    }

    var isVoice: Bool { id == "voice" }
    var isCoding: Bool { id == "coding" }

    /// "Built-in · Off in Auto · Priority 10" — the settings-row subtitle.
    var subtitle: String {
        var bits: [String] = []
        if builtin { bits.append("Built-in") }
        if !enabled { bits.append("Off in Auto") }
        bits.append("Priority \(priority)")
        return bits.joined(separator: " · ")
    }

    var iconName: String {
        if isVoice { return "waveform" }
        if isCoding { return "chevron.left.forwardslash.chevron.right" }
        return "square.grid.2x2"
    }
}

/// Which design is shown: `auto` (rules pick) or `pinned` (a specific entry).
struct IslandSelection: Equatable, Sendable {
    var mode: String            // "auto" | "pinned"
    var pinnedID: String?

    init(mode: String, pinnedID: String? = nil) {
        self.mode = mode
        self.pinnedID = pinnedID
    }

    init(json: JSONObject?) {
        let raw = MoreJSON.text(json?["mode"])
        mode = raw == "pinned" ? "pinned" : "auto"   // unknown mode → auto
        pinnedID = (json?["pinnedId"]).flatMap { $0 is NSNull ? nil : MoreJSON.text($0) }
    }

    var isAuto: Bool { mode == "auto" }
    var isPinned: Bool { mode == "pinned" }

    static let auto = IslandSelection(mode: "auto")
}

/// The whole `GET /api/island/designs` payload.
struct IslandCatalog: Equatable, Sendable {
    var designs: [IslandDesign]
    var entries: [IslandCatalogEntry]
    var selection: IslandSelection
    /// Per-design server-resolved values (jarvis.* etc.), keyed by design id.
    var data: [String: JSONObject]

    static func == (l: IslandCatalog, r: IslandCatalog) -> Bool {
        l.designs == r.designs && l.entries == r.entries && l.selection == r.selection
            && l.data.keys.sorted() == r.data.keys.sorted()
    }

    init(designs: [IslandDesign] = [], entries: [IslandCatalogEntry] = [],
         selection: IslandSelection = .auto, data: [String: JSONObject] = [:]) {
        self.designs = designs
        self.entries = entries
        self.selection = selection
        self.data = data
    }

    init(json: JSONObject) {
        designs = MoreJSON.mapList(json["designs"]).map(IslandDesign.init(json:))
        entries = MoreJSON.mapList(json["catalog"]).map(IslandCatalogEntry.init(json:))
        selection = IslandSelection(json: json["selection"] as? JSONObject)
        var data: [String: JSONObject] = [:]
        for (key, value) in MoreJSON.map(json["data"]) {
            if let inner = value as? JSONObject { data[key] = inner }
        }
        self.data = data
    }

    func design(id: String) -> IslandDesign? { designs.first { $0.id == id } }
    func entry(id: String) -> IslandCatalogEntry? { entries.first { $0.id == id } }
    func data(for id: String) -> JSONObject { data[id] ?? [:] }

    /// Custom (non-built-in) entries — the ones the user can delete.
    var customEntries: [IslandCatalogEntry] { entries.filter { !$0.builtin } }

    static let empty = IslandCatalog()
}

enum IslandParse {
    /// Int with a caller-supplied default (the island payloads default `version`
    /// to 1 and `priority` to 0, so 0 is not a safe universal fallback).
    static func int(_ value: Any?, default fallback: Int) -> Int {
        guard let value, !(value is NSNull) else { return fallback }
        if let s = value as? String { return Int(s) ?? fallback }
        guard let d = MoreJSON.double(value), d.isFinite else { return fallback }
        return Int(d.rounded())
    }
}
