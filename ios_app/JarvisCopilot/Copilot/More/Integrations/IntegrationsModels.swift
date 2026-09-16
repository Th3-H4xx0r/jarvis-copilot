import Foundation

/// An integration: a corner of the registry plus the schedules and skills that
/// belong to it. The list row and the detail screen read the same server
/// payloads the web panel does (`/api/integrations`).
struct Integration: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var summary: String
    var icon: String
    var status: String
    var scheduleCount: Int
    var enabledScheduleCount: Int
    var skillCount: Int
    var collectionCount: Int
    var documentCount: Int
    var recordCount: Int

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        let n = MoreJSON.text(json["name"])
        name = n.isEmpty ? id : n
        summary = MoreJSON.text(json["description"])
        icon = MoreJSON.text(json["icon"])
        let s = MoreJSON.text(json["status"])
        status = s.isEmpty ? "active" : s
        scheduleCount = MoreJSON.int(json["schedule_count"])
        enabledScheduleCount = MoreJSON.int(json["enabled_schedule_count"])
        skillCount = MoreJSON.int(json["skill_count"])
        collectionCount = MoreJSON.int(json["collection_count"])
        documentCount = MoreJSON.int(json["document_count"])
        recordCount = MoreJSON.int(json["record_count"])
    }

    static func == (l: Integration, r: Integration) -> Bool {
        l.id == r.id && l.name == r.name && l.summary == r.summary && l.icon == r.icon
            && l.status == r.status && l.scheduleCount == r.scheduleCount
            && l.enabledScheduleCount == r.enabledScheduleCount && l.skillCount == r.skillCount
            && l.collectionCount == r.collectionCount && l.documentCount == r.documentCount
            && l.recordCount == r.recordCount
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isPaused: Bool { status != "active" }
    var pausedScheduleCount: Int { max(0, scheduleCount - enabledScheduleCount) }

    /// "2 schedules (1 off) · 18 records · 1 skill", or what there is of it.
    var subtitle: String {
        var bits: [String] = []
        if scheduleCount > 0 {
            let off = pausedScheduleCount
            bits.append("\(scheduleCount) \(scheduleCount == 1 ? "schedule" : "schedules")"
                        + (off > 0 ? " (\(off) off)" : ""))
        }
        if recordCount > 0 { bits.append("\(recordCount.formatted()) records") }
        else if documentCount > 0 { bits.append("\(documentCount) stored") }
        if skillCount > 0 { bits.append("\(skillCount) \(skillCount == 1 ? "skill" : "skills")") }
        return bits.isEmpty ? "nothing yet" : bits.joined(separator: " · ")
    }
}

/// Everything one integration's screen shows (`GET /api/integrations/<id>`).
struct IntegrationDetail: Equatable, Sendable {
    var integration: Integration
    var collections: [IntegrationCollection]
    var documents: [IntegrationDocument]
    var skills: [IntegrationSkill]

    init(json: JSONObject) {
        integration = Integration(json: json)
        collections = MoreJSON.mapList(json["collections"]).map(IntegrationCollection.init(json:))
        // imported_files is the one-time workspace migration's own bookkeeping,
        // not data this integration keeps.
        documents = MoreJSON.mapList(json["documents"])
            .map(IntegrationDocument.init(json:))
            .filter { $0.key != "imported_files" }
        skills = MoreJSON.mapList(json["skills"]).map(IntegrationSkill.init(json:))
    }

    var hasNothingStored: Bool { collections.isEmpty && documents.isEmpty }
}

struct IntegrationCollection: Identifiable, Equatable, Sendable {
    var name: String
    var summary: String
    var count: Int
    var id: String { name }

    init(json: JSONObject) {
        name = MoreJSON.text(json["name"])
        summary = MoreJSON.text(json["description"])
        count = MoreJSON.int(json["count"])
    }
}

struct IntegrationDocument: Identifiable, Equatable, Sendable {
    var key: String
    var summary: String
    var bytes: Int
    var id: String { key }

    init(json: JSONObject) {
        key = MoreJSON.text(json["key"])
        summary = MoreJSON.text(json["description"])
        bytes = MoreJSON.int(json["bytes"])
    }

    var sizeLabel: String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

struct IntegrationSkill: Identifiable, Equatable, Sendable {
    var name: String
    var summary: String
    var id: String { name }

    init(json: JSONObject) {
        name = MoreJSON.text(json["name"])
        summary = MoreJSON.text(json["description"])
    }
}

/// One record out of a collection. The registry imposes no shape, so a row is
/// whatever fields it actually carries, plus its time.
struct IntegrationRecord: Identifiable, Equatable, Sendable {
    var id: String
    var ts: Double?
    var fields: [(key: String, value: String)]

    static func == (l: IntegrationRecord, r: IntegrationRecord) -> Bool {
        l.id == r.id && l.ts == r.ts && l.fields.map(\.key) == r.fields.map(\.key)
            && l.fields.map(\.value) == r.fields.map(\.value)
    }

    init(json: JSONObject, index: Int) {
        id = MoreJSON.nonEmpty(json["id"]) ?? "record_\(index)"
        ts = MoreJSON.double(json["ts"])
        fields = json.keys.sorted()
            .filter { $0 != "ts" && $0 != "id" }
            .map { ($0, IntegrationRecord.display(json[$0])) }
    }

    private static func display(_ value: Any?) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if let value, !(value is NSNull),
           JSONSerialization.isValidJSONObject([value]),
           value is [Any] || value is JSONObject,
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(200))
        }
        return String(MoreJSON.text(value).prefix(200))
    }

    var timeLabel: String { ts.map { RelativeTime.absolute(Date(timeIntervalSince1970: $0)) } ?? "" }
}

/// A proposed integration, as the plan card in chat renders it. Nothing in here
/// exists on the server yet unless `status` says it was approved.
struct IntegrationPlan: Identifiable, Equatable, Sendable {
    var id: String
    var spaceID: String
    var name: String
    var summary: String
    var icon: String
    var status: String
    var schedules: [PlanSchedule]
    var collections: [PlanItem]
    var skills: [PlanItem]

    struct PlanSchedule: Identifiable, Equatable, Sendable {
        var name: String
        var when: String
        var purpose: String
        var id: String { name }
    }

    struct PlanItem: Identifiable, Equatable, Sendable {
        var name: String
        var summary: String
        var id: String { name }
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        spaceID = MoreJSON.text(json["space_id"])
        name = MoreJSON.text(json["name"])
        summary = MoreJSON.text(json["summary"])
        icon = MoreJSON.text(json["icon"])
        let s = MoreJSON.text(json["status"])
        status = s.isEmpty ? "pending" : s
        schedules = MoreJSON.mapList(json["schedules"]).map {
            PlanSchedule(name: MoreJSON.text($0["name"]),
                         when: MoreJSON.text($0["schedule"]),
                         purpose: MoreJSON.text($0["purpose"]))
        }
        collections = MoreJSON.mapList(json["collections"]).map {
            PlanItem(name: MoreJSON.text($0["name"]), summary: MoreJSON.text($0["description"]))
        }
        skills = MoreJSON.mapList(json["skills"]).map {
            PlanItem(name: MoreJSON.text($0["name"]), summary: MoreJSON.text($0["purpose"]))
        }
    }

    var isPending: Bool { status == "pending" }

    var statusLabel: String {
        switch status {
        case "approved": return "CREATED"
        case "cancelled": return "CANCELLED"
        default: return "PROPOSED"
        }
    }
}

/// One glyph per integration. `icon` is a plain word so each platform draws it
/// its own way; on the phone that means a Phosphor icon.
enum IntegrationIcon {
    static func symbol(for icon: String) -> String {
        switch icon.lowercased() {
        case "music":    return "music.note"
        case "envelope": return "envelope"
        case "house":    return "house"
        case "airplane": return "airplane"
        case "chips":    return "dice"
        case "chart":    return "chart.line.uptrend.xyaxis"
        case "clock":    return "clock"
        case "bolt":     return "bolt"
        case "book":     return "book"
        case "heart":    return "heart"
        case "dots":     return "ellipsis"
        default:         return "square.grid.2x2"
        }
    }
}

/// What "delete this skill" means. Unlinking is cheap to undo; taking it out of
/// service moves its folder somewhere nothing loads it.
enum SkillDeleteMode: String, Sendable {
    case unlink
    case file
}

/// Which parts of an integration a delete should take. Everything is on by
/// default except the skills' files, because unlinking a skill is recoverable and
/// removing it is a separate decision.
struct IntegrationDeleteChoice: Equatable, Sendable {
    var schedules = true
    var data = true
    var skills = true
    var skillFiles = false
    var space = true

    var body: JSONObject {
        ["schedules": schedules, "data": data, "skills": skills,
         "skill_files": skillFiles, "space": space]
    }

    /// Nothing selected means nothing to do — the Delete button stays disabled.
    var isEmpty: Bool { !schedules && !data && !skills && !space }

    /// One line naming what will go, so the confirmation is specific.
    func summary(schedules scheduleCount: Int, collections: Int,
                 documents: Int, skills skillCount: Int) -> String {
        var parts: [String] = []
        if schedules && scheduleCount > 0 {
            parts.append("\(scheduleCount) \(scheduleCount == 1 ? "schedule" : "schedules")")
        }
        if data && (collections + documents) > 0 {
            let total = collections + documents
            parts.append("\(total) \(total == 1 ? "data set" : "data sets")")
        }
        if skills && skillCount > 0 {
            parts.append("\(skillCount) \(skillCount == 1 ? "skill" : "skills")"
                         + (skillFiles ? " (and their files)" : ""))
        }
        if space { parts.append("the integration itself") }
        if parts.isEmpty { return "Nothing selected." }
        if parts.count == 1 { return "This removes \(parts[0]). It cannot be undone." }
        let last = parts.removeLast()
        return "This removes \(parts.joined(separator: ", ")) and \(last). It cannot be undone."
    }
}
