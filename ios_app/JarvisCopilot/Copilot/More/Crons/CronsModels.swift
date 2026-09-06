import Foundation

/// One scheduled job. The raw payload is kept because the create/edit form
/// round-trips fields this struct doesn't name (model, profile, skills, …).
struct CronJob: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var prompt: String
    var deliver: String
    var skills: [String]
    var model: String
    var profile: String
    var toastNotifications: Bool
    var raw: JSONObject

    static func == (l: CronJob, r: CronJob) -> Bool {
        l.id == r.id && l.name == r.name && l.prompt == r.prompt
            && l.deliver == r.deliver && l.skills == r.skills && l.model == r.model
            && l.profile == r.profile && l.toastNotifications == r.toastNotifications
            && l.statusKey == r.statusKey && l.schedule == r.schedule
    }

    init(json: JSONObject) {
        id = Crons.jobID(json)
        name = MoreJSON.text(json["name"])
        prompt = MoreJSON.text(json["prompt"])
        let d = MoreJSON.text(json["deliver"])
        deliver = d.isEmpty ? "local" : d
        skills = MoreJSON.stringList(json["skills"])
        model = MoreJSON.text(json["model"])
        profile = MoreJSON.text(json["profile"])
        // Absent → true (the Flutter form defaults new jobs to toasts on).
        toastNotifications = (json["toast_notifications"] as? Bool) ?? true
        raw = json
    }

    var title: String { name.isEmpty ? (prompt.isEmpty ? id : prompt) : name }
    var statusKey: String { Crons.statusKey(raw) }
    var statusLabel: String { Crons.statusLabel(statusKey) }
    var statusTone: MoreTone { Crons.statusTone(statusKey) }
    var isPaused: Bool { Crons.isPaused(raw) }
    var isRunning: Bool { statusKey == "running" }
    var schedule: String { Crons.schedule(raw) }

    func nextRunLabel(now: Date = Date()) -> String {
        Crons.formatTime(raw["next_run"] ?? raw["next_run_at"], now: now)
    }

    func lastRunLabel(now: Date = Date()) -> String {
        Crons.formatTime(raw["last_run"] ?? raw["last_run_at"], now: now)
    }
}

/// One entry in a job's run history (`GET /api/crons/history`).
struct CronRun: Identifiable, Equatable, Sendable {
    var filename: String
    var ts: String
    var status: String
    var size: Int?
    /// Stable key even when the server sent no filename.
    var id: String

    init(json: JSONObject, index: Int) {
        filename = MoreJSON.text(json["filename"])
        ts = MoreJSON.text(json["ts"] ?? json["modified"])
        status = MoreJSON.text(json["status"])
        size = json["size"].flatMap { $0 is NSNull ? nil : MoreJSON.int($0) }
        id = filename.isEmpty ? "run_\(index)" : filename
    }

    /// "2026-06-22 0930" style — the filename with `.md` and `_` cleaned up,
    /// falling back to the timestamp and then to "Run".
    var label: String {
        if !filename.isEmpty {
            return filename.replacingOccurrences(of: ".md", with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
        return ts.isEmpty ? "Run" : ts
    }

    /// "12.5 KB", or nil when the server sent no size.
    var subtitle: String? {
        guard let size else { return nil }
        return String(format: "%.1f KB", Double(size) / 1024)
    }
}

/// Where a job's results are delivered.
enum CronDeliver {
    static let options = ["local", "origin", "telegram", "discord", "slack"]

    static func label(_ d: String) -> String {
        switch d {
        case "local": return "In-app only"
        case "origin": return "Originating chat"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "slack": return "Slack"
        default:
            guard let first = d.first else { return "—" }
            return first.uppercased() + d.dropFirst()
        }
    }

    static func iconName(_ d: String) -> String {
        switch d {
        case "local": return "iphone"
        case "origin": return "arrowshape.turn.up.left"
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        case "slack": return "number"
        default: return "bell"
        }
    }
}

/// Pure helpers for the cron payloads (ported case-for-case from `crons.dart`).
enum Crons {
    /// A job's id. The server stores it under `id`; the mobile spec and some
    /// legacy payloads use `job_id`, which wins when both are present.
    static func jobID(_ job: JSONObject) -> String {
        MoreJSON.text(job["job_id"] ?? job["id"])
    }

    /// A human-readable status key.
    ///
    /// The server returns a structured `state` (scheduled/paused/completed/error)
    /// plus `enabled` and a `last_status`; the spec also allows a flat `status`
    /// string, which wins. Mirrors the web panel's `_cronStatusMeta` precedence.
    static func statusKey(_ job: JSONObject) -> String {
        let flat = MoreJSON.text(job["status"]).trimmingCharacters(in: .whitespaces).lowercased()
        if !flat.isEmpty { return flat }

        let state = MoreJSON.text(job["state"]).trimmingCharacters(in: .whitespaces).lowercased()
        let lastStatus = MoreJSON.text(job["last_status"])
            .trimmingCharacters(in: .whitespaces).lowercased()
        let enabled = job["enabled"] as? Bool
        let next = job["next_run"] ?? job["next_run_at"]
        let hasNext = next != nil && !(next is NSNull) && !MoreJSON.text(next).isEmpty

        if !hasNext && (state == "error" || lastStatus == "error") { return "needs_attention" }
        if state == "paused" { return "paused" }
        if enabled == false { return "off" }
        if lastStatus == "error" || state == "error" { return "error" }
        if state == "running" { return "running" }
        if !state.isEmpty { return state }
        return "active"
    }

    /// Short uppercase badge label for a status key.
    static func statusLabel(_ key: String) -> String {
        switch key.lowercased() {
        case "running": return "RUNNING"
        case "paused": return "PAUSED"
        case "off", "disabled": return "OFF"
        case "error": return "ERROR"
        case "needs_attention", "schedule_error": return "NEEDS ATTENTION"
        case "completed": return "COMPLETED"
        case "scheduled", "active": return "ACTIVE"
        default: return key.isEmpty ? "ACTIVE" : key.uppercased()
        }
    }

    /// Badge palette slot. (The Flutter version returned a `JcTheme` colour;
    /// this layer stays view-free, so wave-2 maps the token.)
    static func statusTone(_ key: String) -> MoreTone {
        switch key.lowercased() {
        case "running": return .primaryBlue
        case "paused", "off", "disabled", "completed": return .muted
        case "error", "needs_attention", "schedule_error": return .danger
        default: return .success
        }
    }

    /// True when the job is paused — drives the Pause/Resume action choice.
    static func isPaused(_ job: JSONObject) -> Bool {
        statusKey(job) == "paused"
            || MoreJSON.text(job["state"]).trimmingCharacters(in: .whitespaces).lowercased() == "paused"
    }

    /// The human schedule string. The server stores `schedule` as a dict and
    /// exposes `schedule_display`; a flat `schedule` string is also allowed.
    static func schedule(_ job: JSONObject) -> String {
        let display = MoreJSON.text(job["schedule_display"]).trimmingCharacters(in: .whitespaces)
        if !display.isEmpty { return display }
        if let s = job["schedule"] as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        if let dict = job["schedule"] as? JSONObject {
            for key in ["display", "expression", "value", "expr", "run_at"] {
                let v = MoreJSON.text(dict[key]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return ""
    }

    /// Format a run timestamp (ISO-8601, or epoch seconds/ms) as a clean local
    /// string like "Jun 22, 6:30 AM" — or a relative "in 4m" / "2h ago" when
    /// it's within a day of now. "" for empty input; the raw string when
    /// unparseable (the server sometimes sends prose like "never").
    static func formatTime(_ value: Any?, relativeNear: Bool = true, now: Date = Date()) -> String {
        let s = MoreJSON.text(value).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }

        // ISO first: a bare number must keep its epoch meaning, and Dart's
        // DateTime.tryParse rejects bare numbers anyway.
        var date = RelativeTime.parseISOString(s)
        if date == nil, let n = Double(s) {
            let ms = n > 100_000_000_000 ? n : n * 1000
            date = Date(timeIntervalSince1970: ms / 1000)
        }
        guard let date else { return s }

        if relativeNear {
            let seconds = date.timeIntervalSince(now)
            let minutes = Int(seconds / 60)
            if abs(minutes) < 60 {
                if minutes == 0 { return "now" }
                return minutes > 0 ? "in \(minutes)m" : "\(-minutes)m ago"
            }
            let hours = Int(seconds / 3600)
            if abs(hours) < 24 {
                return hours > 0 ? "in \(hours)h" : "\(-hours)h ago"
            }
        }

        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let ampm = hour24 < 12 ? "AM" : "PM"
        let month = RelativeTime.months[max(0, min(11, (c.month ?? 1) - 1))]
        return String(format: "%@ %d, %d:%02d %@", month, c.day ?? 0, hour12, c.minute ?? 0, ampm)
    }
}
