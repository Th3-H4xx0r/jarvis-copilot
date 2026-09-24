import Foundation
import Observation

/// One line a voice said, from `/api/live/speaker_lines`.
struct LiveSpeakerLine: Identifiable, Equatable, Sendable {
    var sessionID = ""
    var seq = 0
    /// When it was said: the session's start plus the line's offset.
    var at = Date(timeIntervalSince1970: 0)
    var text = ""
    var lang = ""
    var translation: String?
    var sessionTitle = ""

    var id: String { "\(sessionID)#\(seq)" }

    static func from(_ d: [String: Any]) -> LiveSpeakerLine {
        LiveSpeakerLine(sessionID: d.string("live_session_id") ?? "",
                        seq: d.int("seq") ?? 0,
                        at: Date(timeIntervalSince1970: d.double("at") ?? 0),
                        text: d.string("text") ?? "",
                        lang: d.string("lang") ?? "",
                        translation: d.string("translation").flatMap { $0.isEmpty ? nil : $0 },
                        sessionTitle: d.string("session_title") ?? "")
    }
}

struct LiveSpeakerLinesPage: Sendable {
    var lines: [LiveSpeakerLine]
    /// The cursor for the page after this one; nil at the end.
    var next: String?
    var total: Int
}

/// A voice's whole history for the Voices screens, newest first, a page at a
/// time — the next page when the last line comes on screen, never two requests
/// at once, and nothing asked for after the end.
@MainActor
@Observable
final class LiveVoiceHistory {
    static let pageSize = 50

    let speakerID: String
    private let api: LiveAPI

    private(set) var lines: [LiveSpeakerLine] = []
    private(set) var total = 0
    private(set) var loading = false
    private(set) var done = false
    private(set) var error = ""
    private var next: String?

    init(speakerID: String, api: LiveAPI) {
        self.speakerID = speakerID
        self.api = api
    }

    func loadMore() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.speakerLines(speakerID: speakerID, before: next, limit: Self.pageSize)
            lines.append(contentsOf: page.lines)
            total = max(page.total, lines.count)
            next = page.next
            done = page.next == nil
            error = ""
        } catch {
            self.error = "Could not load what this voice said."
            JcLog.dropped(JcLog.voice, "load a voice's lines", error)
        }
    }
}
