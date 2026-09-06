import Foundation

/// The log files `GET /api/logs` will serve, mirroring the backend's
/// `_LOG_FILE_WHITELIST`. Any other `file` value answers HTTP 400.
let serverLogFiles: [String] = ["agent", "errors", "gateway"]

/// Coarse severity bucket for one log line.
enum LogSeverity: String, Equatable, Sendable {
    case error, warn, info

    var tone: MoreTone {
        switch self {
        case .error: return .danger
        // The palette has no amber-for-logs slot in the Flutter original — a
        // warm blue reads as the caution tier there, so keep that mapping.
        case .warn: return .blue
        case .info: return .muted
        }
    }
}

/// Severity filter modes (mirrors the web panel: all / warnings+ / errors).
enum LogSeverityFilter: String, CaseIterable, Identifiable, Sendable {
    case all, warnings, errors

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .warnings: return "Warnings+"
        case .errors: return "Errors"
        }
    }

    func admits(_ severity: LogSeverity) -> Bool {
        switch self {
        case .all: return true
        case .errors: return severity == .error
        case .warnings: return severity == .warn || severity == .error
        }
    }
}

/// Classify a line, matching the web panel's `_severityForLine`
/// (case-insensitive): ERROR / CRITICAL / Traceback / Exception → error;
/// WARN / WARNING → warn; everything else → info.
func logSeverity(_ line: String) -> LogSeverity {
    let upper = line.uppercased()
    if upper.contains("ERROR") || upper.contains("CRITICAL")
        || upper.contains("TRACEBACK") || upper.contains("EXCEPTION") {
        return .error
    }
    if upper.contains("WARN") { return .warn }
    return .info
}

/// Normalise the `/api/logs` body into a flat list of lines.
///
/// The real backend returns `{lines: [...]}`, but a single `{content: "a\nb"}`
/// string, a bare list and a bare string are all tolerated — splitting on
/// newlines and dropping the spurious empty element a trailing newline creates.
func parseLogLines(_ data: Any?) -> [String] {
    var raw: Any?
    if let object = data as? JSONObject {
        raw = object["lines"] ?? object["content"]
    } else {
        raw = data
    }
    if let list = raw as? [Any] {
        return list.map { MoreJSON.text($0) }
    }
    if let text = raw as? String {
        var parts = text.components(separatedBy: "\n")
        if let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }
    return []
}

/// One `GET /api/logs` reply: the lines plus the passthrough metadata.
struct ServerLogTail: Equatable, Sendable {
    var file: String
    var tail: Int
    var lines: [String]
    var truncated: Bool
    var totalBytes: Int
    /// Epoch seconds as the server sent it, or nil.
    var mtime: Double?
    var hint: String

    init(file: String = "agent", tail: Int = 1000, lines: [String] = [],
         truncated: Bool = false, totalBytes: Int = 0,
         mtime: Double? = nil, hint: String = "") {
        self.file = file
        self.tail = tail
        self.lines = lines
        self.truncated = truncated
        self.totalBytes = totalBytes
        self.mtime = mtime
        self.hint = hint
    }

    init(json: JSONObject, requestedFile: String, requestedTail: Int) {
        let file = MoreJSON.nonEmpty(json["file"]) ?? requestedFile
        self.file = file
        tail = json["tail"] != nil ? MoreJSON.int(json["tail"], or: requestedTail) : requestedTail
        lines = parseLogLines(json)
        truncated = MoreJSON.isTrue(json["truncated"])
        totalBytes = MoreJSON.int(json["total_bytes"])
        mtime = MoreJSON.double(json["mtime"])
        hint = MoreJSON.text(json["hint"])
    }

    /// "Updated 5m ago", or "" when the server sent no mtime.
    func mtimeLabel(now: Date = Date()) -> String {
        guard let mtime, mtime > 0 else { return "" }
        return RelativeTime.format(mtime, now: now)
    }

    var sizeLabel: String { totalBytes > 0 ? Insights.formatBytes(totalBytes) : "" }
}
