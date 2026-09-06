import Foundation

/// The pure formatting the chat views need. Kept out of the views so it can be
/// tested without rendering anything, and out of ``ChatStore`` because none of it
/// is state.

enum ChatUIFormat {

    /// The label for the header's model capsule. Mirrors the Flutter
    /// `ModelChip._label()` + `Esp32ChatView.shortName`: no catalogue lookup, just
    /// a readable name derived from the id's last segment.
    static func shortModelName(_ raw: String, limit: Int = 18) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Auto" }
        if let slash = name.lastIndex(of: "/"), slash < name.index(before: name.endIndex) {
            name = String(name[name.index(after: slash)...])
        }
        if let colon = name.lastIndex(of: ":"), colon < name.index(before: name.endIndex) {
            name = String(name[name.index(after: colon)...])
        }
        return truncate(name, limit: limit)
    }

    /// Clip to `limit` *including* the ellipsis, so a fixed-width capsule or a
    /// one-line row never has to measure the string itself.
    static func truncate(_ text: String, limit: Int) -> String {
        let squeezed = text.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard squeezed.count > limit, limit > 1 else { return squeezed }
        return String(squeezed.prefix(limit - 1)) + "…"
    }

    /// The size line on an attachment chip. Binary units, because that is what
    /// `ChatPendingAttachment.maxVideoBytes` (100 MB) counts in.
    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_024 * 1_024 { return "\(Int((Double(bytes) / 1_024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
}

/// One section of the sessions sheet. Pinned chats float to the top whatever
/// their date; the rest fall into Today / Yesterday / Earlier, which is as much
/// granularity as a phone-sized list wants.
struct ChatSessionGroup: Identifiable, Equatable, Sendable {
    var title: String
    var sessions: [ChatSessionSummary]
    var id: String { title }

    /// Group `sessions` (already newest-first from ``ChatStore``) for display,
    /// keeping the incoming order inside every bucket. `query` filters on the
    /// displayed title, case- and whitespace-insensitively; empty groups are
    /// dropped so the sheet never shows a bare header.
    static func group(_ sessions: [ChatSessionSummary],
                      query: String = "",
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [ChatSessionGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = needle.isEmpty
            ? sessions
            : sessions.filter { $0.displayTitle.lowercased().contains(needle) }

        var pinned: [ChatSessionSummary] = []
        var today: [ChatSessionSummary] = []
        var yesterday: [ChatSessionSummary] = []
        var earlier: [ChatSessionSummary] = []

        for session in matching {
            if session.pinned { pinned.append(session); continue }
            guard let stamp = session.updatedAt else { earlier.append(session); continue }
            let date = Date(timeIntervalSince1970: TimeInterval(stamp))
            if calendar.isDate(date, inSameDayAs: now) {
                today.append(session)
            } else if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(date, inSameDayAs: dayBefore) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        return [("Pinned", pinned), ("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
            .map { ChatSessionGroup(title: $0.0, sessions: $0.1) }
    }
}
