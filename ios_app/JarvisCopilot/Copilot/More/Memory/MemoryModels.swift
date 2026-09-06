import Foundation

/// The two long-term memory files the agent keeps, in the order the web UI
/// shows them. `wireKey` is what `/api/memory/write` expects.
enum MemorySection: String, CaseIterable, Identifiable, Sendable {
    case memory
    case user

    var id: String { rawValue }
    var wireKey: String { rawValue }
    var label: String { self == .user ? "User Profile" : "My Notes" }
    var iconName: String { self == .user ? "person" : "brain" }
    var emptyText: String { self == .user ? "No profile yet." : "No notes yet." }
    var emptyHint: String {
        self == .user
            ? "Tap the pencil to tell the agent about yourself."
            : "Tap the pencil to jot down notes for the agent."
    }

    /// Keys into the `GET /api/memory` response.
    var contentKey: String { self == .user ? "user" : "memory" }
    var mtimeKey: String { self == .user ? "user_mtime" : "memory_mtime" }
    var pathKey: String { self == .user ? "user_path" : "memory_path" }
}

/// `GET /api/memory` — both files plus their paths and mtimes. Missing keys are
/// tolerated (text defaults to "", paths/mtimes to nil) so a partial or older
/// server response still renders.
struct MemoryDocuments: Equatable, Sendable {
    var memory: String = ""
    var user: String = ""
    var memoryPath: String?
    var userPath: String?
    /// Raw mtimes stay stringly-typed: the server sends epoch seconds as a
    /// number, but older builds sent a pre-formatted string.
    var memoryMtime: String?
    var userMtime: String?

    /// True before anything has loaded — the Edit button stays disabled.
    var isEmpty: Bool {
        memory.isEmpty && user.isEmpty && memoryPath == nil && userPath == nil
    }

    init() {}

    init(json: JSONObject) {
        memory = MoreJSON.text(json["memory"])
        user = MoreJSON.text(json["user"])
        memoryPath = MoreJSON.nonEmpty(json["memory_path"])
        userPath = MoreJSON.nonEmpty(json["user_path"])
        memoryMtime = MoreJSON.nonEmpty(json["memory_mtime"])
        userMtime = MoreJSON.nonEmpty(json["user_mtime"])
    }

    func content(for section: MemorySection) -> String {
        section == .user ? user : memory
    }

    func path(for section: MemorySection) -> String? {
        section == .user ? userPath : memoryPath
    }

    func rawMtime(for section: MemorySection) -> String? {
        section == .user ? userMtime : memoryMtime
    }

    /// Formatted mtime line, or "" when the caller should hide it.
    func mtimeLabel(for section: MemorySection) -> String {
        MemoryMtime.format(rawMtime(for: section))
    }
}

/// Formats a memory file's last-modified time for display.
///
/// The server sends a unix epoch in SECONDS (e.g. 1718900000.123) but we
/// tolerate anything: a number or numeric string becomes an absolute local
/// date-time; nil/empty/zero/negative becomes "" (the caller hides the line);
/// any other non-empty string is already human-readable and passes through.
enum MemoryMtime {
    static func format(_ mtime: Any?) -> String {
        guard let mtime, !(mtime is NSNull) else { return "" }

        let epochSeconds: Double
        if let raw = mtime as? String {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return "" }
            guard let parsed = Double(s) else { return s }  // already formatted
            epochSeconds = parsed
        } else if let n = numeric(mtime) {
            epochSeconds = n
        } else {
            return ""
        }

        guard epochSeconds > 0 else { return "" }
        let seconds = epochSeconds
        return RelativeTime.absolute(Date(timeIntervalSince1970: seconds))
    }

    private static func numeric(_ v: Any) -> Double? {
        if v is Bool { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}
