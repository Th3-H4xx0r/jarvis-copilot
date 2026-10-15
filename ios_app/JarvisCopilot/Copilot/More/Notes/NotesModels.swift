import Foundation

/// A call noted by the Jarvis Mac app's note-taker, as the server keeps it
/// (`agent/agent_notes.py`). The list sends every field but the transcript
/// (`line_count` and `duration` instead); one note sends it all.
struct AgentNote: Identifiable, Hashable {
    enum SummaryStatus: String { case none, pending, done, failed }

    struct Speaker: Hashable {
        let id: String
        let name: String
        let isMe: Bool
    }

    struct Line: Hashable, Identifiable {
        let id: Int
        let speaker: String
        let start: Double
        let end: Double
        let text: String
    }

    struct Todo: Hashable, Identifiable {
        let id: Int
        let text: String
        let owner: String?
        let due: String?
        let done: Bool
    }

    let id: String
    let title: String
    let start: Date
    let end: Date?
    let app: String?
    let speakers: [Speaker]
    let lines: [Line]
    let summary: String?
    let keyPoints: [String]
    let todos: [Todo]
    let summaryStatus: SummaryStatus
    let summaryError: String?
    let lineCount: Int
    let duration: TimeInterval

    init?(json: [String: Any]) {
        guard let id = CodingJSON.str(json["id"]), !id.isEmpty else { return nil }
        self.id = id
        title = CodingJSON.str(json["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Call notes"
        let startSeconds = CodingJSON.double(json["start"]) ?? 0
        start = Date(timeIntervalSince1970: startSeconds)
        end = CodingJSON.double(json["end"]).map { Date(timeIntervalSince1970: $0) }
        app = CodingJSON.str(json["app"]).flatMap { $0.isEmpty ? nil : $0 }
        speakers = CodingJSON.maps(json["speakers"]).compactMap { s in
            guard let id = CodingJSON.str(s["id"]), !id.isEmpty else { return nil }
            return Speaker(id: id, name: CodingJSON.str(s["name"]) ?? id, isMe: CodingJSON.bool(s["is_me"]))
        }
        lines = CodingJSON.maps(json["lines"]).enumerated().compactMap { i, l in
            guard let text = CodingJSON.str(l["text"]), !text.isEmpty else { return nil }
            let start = CodingJSON.double(l["start"]) ?? 0
            return Line(id: i, speaker: CodingJSON.str(l["speaker"]) ?? "them", start: start,
                        end: CodingJSON.double(l["end"]) ?? start, text: text)
        }
        summary = CodingJSON.str(json["summary"]).flatMap { $0.isEmpty ? nil : $0 }
        keyPoints = CodingJSON.strings(json["key_points"]).filter { !$0.isEmpty }
        todos = CodingJSON.maps(json["todos"]).enumerated().compactMap { i, t in
            guard let text = CodingJSON.str(t["text"]), !text.isEmpty else { return nil }
            return Todo(id: i, text: text, owner: CodingJSON.str(t["owner"]).flatMap { $0.isEmpty ? nil : $0 },
                        due: CodingJSON.str(t["due"]).flatMap { $0.isEmpty ? nil : $0 }, done: CodingJSON.bool(t["done"]))
        }
        summaryStatus = CodingJSON.str(json["summary_status"]).flatMap(SummaryStatus.init(rawValue:)) ?? .none
        summaryError = CodingJSON.str(json["summary_error"]).flatMap { $0.isEmpty ? nil : $0 }
        lineCount = json["line_count"] != nil ? CodingJSON.int(json["line_count"]) : lines.count
        if let d = CodingJSON.double(json["duration"]) {
            duration = max(0, d)
        } else {
            duration = max(0, (end?.timeIntervalSince1970 ?? startSeconds) - startSeconds)
        }
    }

    var minutes: Int { max(1, Int((duration / 60).rounded())) }

    /// "You" for the Mac's microphone, "Them" for its sound, unless renamed.
    func name(of speaker: String) -> String {
        if let s = speakers.first(where: { $0.id == speaker }) { return s.name }
        return speaker == "me" ? "You" : "Them"
    }

    func isMe(_ speaker: String) -> Bool {
        speakers.first(where: { $0.id == speaker })?.isMe ?? (speaker == "me")
    }

    /// The to-dos as the server takes them back, one of them ticked or unticked.
    func todosJSON(toggling index: Int) -> [[String: Any]] {
        todos.map { t in
            ["text": t.text, "owner": t.owner ?? NSNull(), "due": t.due ?? NSNull(),
             "done": t.id == index ? !t.done : t.done]
        }
    }

    /// m:ss or h:mm:ss from the start of the call.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
