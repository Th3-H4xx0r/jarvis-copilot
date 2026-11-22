import Foundation

/// Every command the Meta glasses received — from Jarvis's tools, the touchpad, the capture button,
/// a voice turn or a sim control — with what happened. The Sim screen's live feed; the Device screen
/// shows the same feed for the real glasses.
@MainActor
final class MetaCommandFeed: ObservableObject {
    static let shared = MetaCommandFeed()

    enum Source: String, Sendable {
        case jarvis = "Jarvis"
        case touch = "Touch"
        case captureButton = "Capture button"
        case voice = "Voice"
        case sim = "Sim"
        case glasses = "Glasses"
    }

    enum Outcome: Equatable, Sendable {
        case done
        case refused(String)
        case info
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let source: Source
        let title: String
        let detail: String?
        let outcome: Outcome
        /// A small JPEG for captures.
        let thumbnail: Data?
    }

    static let capacity = 200
    @Published private(set) var entries: [Entry] = []
    private var nextID = 0

    @discardableResult
    func log(_ source: Source, _ title: String, detail: String? = nil, outcome: Outcome = .done,
             thumbnail: Data? = nil) -> Entry {
        let entry = Entry(id: nextID, date: Date(), source: source, title: title, detail: detail,
                          outcome: outcome, thumbnail: thumbnail)
        nextID += 1
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        return entry
    }

    func clear() { entries.removeAll() }
}
