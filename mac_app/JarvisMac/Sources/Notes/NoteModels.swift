import Foundation

/// Someone in a call. Without speaker diarization the transcript is labelled
/// by source: "You" for the microphone, "Them" for what the Mac plays.
struct NoteSpeaker: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var isMe = false
}

/// One turn of speech.
struct NoteLine: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var speaker: String
    /// Seconds from the start of the recording.
    var start: Double
    var end: Double
    var text: String
}

struct NoteTodo: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var done = false
}

/// A call noted by the note-taker. Saved on this Mac, uploaded to the server
/// (`/api/agent-notes`) so the phone sees it; the summary comes back from there.
struct Note: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording, transcribing, ready, failed
    }

    enum SummaryStatus: String, Codable, Sendable {
        case none, pending, done, failed
    }

    var id = UUID()
    var title: String
    /// Set once you rename the note: the summary then keeps your title.
    var titleEdited = false
    var start: Date
    var end: Date?
    /// The call app in front when the recording started ("Zoom", "Google Chrome").
    var app: String?
    var status: Status = .recording
    var speakers: [NoteSpeaker] = []
    var lines: [NoteLine] = []
    var summary: String?
    var keyPoints: [String] = []
    var todos: [NoteTodo] = []
    var summaryStatus: SummaryStatus = .none
    var summaryError: String?
    /// The server has this version.
    var uploaded = false
    var error: String?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    func speaker(_ id: String) -> NoteSpeaker? { speakers.first { $0.id == id } }

    func name(of speakerID: String) -> String {
        speaker(speakerID)?.name ?? (speakerID == NoteBuilder.meID ? NoteBuilder.meName : NoteBuilder.themName)
    }

    // MARK: server

    /// The upload (`POST /api/agent-notes`), in the server's shape (agent/agent_notes.py).
    var serverJSON: [String: Any] {
        [
            "id": id.uuidString,
            "title": title,
            "title_edited": titleEdited,
            "start": start.timeIntervalSince1970,
            "end": end.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "app": app ?? NSNull(),
            "speakers": speakers.map { ["id": $0.id, "name": $0.name, "is_me": $0.isMe] as [String: Any] },
            "lines": lines.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] },
            "summary": summary ?? NSNull(),
            "key_points": keyPoints,
            "todos": todos.map { t -> [String: Any] in
                ["text": t.text, "owner": t.owner ?? NSNull(), "due": t.due ?? NSNull(), "done": t.done]
            },
        ]
    }

    /// Takes in what the server wrote: the summary, key points, to-dos, and the
    /// summary's title unless you renamed the note. A failure never erases a
    /// summary that was there.
    mutating func absorb(server json: [String: Any]) {
        if let status = (json["summary_status"] as? String).flatMap(SummaryStatus.init(rawValue:)) {
            summaryStatus = status
        }
        summaryError = (json["summary_error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard summaryStatus == .done else { return }
        if !titleEdited, let t = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            title = t
        }
        if let s = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            summary = s
        }
        if let points = json["key_points"] as? [Any] {
            keyPoints = points.compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
        }
        if let raw = json["todos"] as? [Any] {
            todos = raw.compactMap { item -> NoteTodo? in
                guard let d = item as? [String: Any], let text = d["text"] as? String, !text.isEmpty else { return nil }
                func field(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                return NoteTodo(text: text, owner: field("owner"), due: field("due"), done: d["done"] as? Bool ?? false)
            }
        }
    }
}

/// A word with its place in the audio, in seconds.
struct TimedWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Builds the transcript of a call from the two recordings (Tests/NotesTests.swift):
/// the microphone is you, the Mac's sound is the other side.
/// After coucou's NoteBuilder (github.com/Louis-CFM/coucou, MIT).
enum NoteBuilder {
    /// Words further apart than this start a new line.
    static let pause = 1.4
    /// A line never gets longer than this, so the transcript stays readable.
    static let maxLineSeconds = 40.0

    static let meID = "me"
    static let themID = "them"
    static var meName: String { String(localized: "You") }
    static var themName: String { String(localized: "Them") }

    /// Consecutive words of one speaker, close in time, make one line.
    static func lines(speaker: String, words: [TimedWord]) -> [NoteLine] {
        var out: [NoteLine] = []
        for word in words {
            if var last = out.last, word.start - last.end < pause, word.end - last.start <= maxLineSeconds {
                last.text += " " + word.text
                last.end = word.end
                out[out.count - 1] = last
            } else {
                out.append(NoteLine(speaker: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return out
    }

    /// The words of a chunk that started `offset` seconds into the recording.
    static func offset(_ words: [TimedWord], by offset: Double) -> [TimedWord] {
        words.map { TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
    }

    /// Keeps the live transcript in time order as chunks of both sides come in.
    static func insert(_ line: NoteLine, into lines: inout [NoteLine]) {
        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
    }

    /// Without headphones, the other side comes out of the speakers and into the
    /// microphone too. A line of yours whose words their recording also has, at
    /// the same moment, is that echo.
    static func removingEcho(mine: [NoteLine], others: [NoteLine]) -> [NoteLine] {
        mine.filter { line in
            let words = tokens(line.text)
            guard words.count >= 2 else {
                return !others.contains { overlaps($0, line, margin: 0.8) && tokens($0.text).contains(words.first ?? "") }
            }
            let near = others.filter { overlaps($0, line, margin: 1.5) }.flatMap { tokens($0.text) }
            guard !near.isEmpty else { return true }
            let pool = Set(near)
            let shared = words.filter { pool.contains($0) }.count
            return Double(shared) / Double(words.count) < 0.6
        }
    }

    private static func overlaps(_ a: NoteLine, _ b: NoteLine, margin: Double) -> Bool {
        a.start < b.end + margin && b.start < a.end + margin
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The whole transcript from the lines of both sides: your echo removed, time
    /// order, "You" and "Them" as speakers.
    static func finalize(_ all: [NoteLine]) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        let mine = all.filter { $0.speaker == meID }
        let theirs = all.filter { $0.speaker != meID }
        let lines = (removingEcho(mine: mine, others: theirs) + theirs).sorted { $0.start < $1.start }
        var speakers: [NoteSpeaker] = []
        if !mine.isEmpty || theirs.isEmpty { speakers.append(NoteSpeaker(id: meID, name: meName, isMe: true)) }
        if !theirs.isEmpty { speakers.append(NoteSpeaker(id: themID, name: themName)) }
        return (speakers, lines)
    }

    static func build(mine: [TimedWord], others: [TimedWord]) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        finalize(lines(speaker: meID, words: mine) + lines(speaker: themID, words: others))
    }

    // MARK: Markdown

    /// The note as Markdown: title, date, summary, key points, to-dos, transcript.
    static func markdown(_ note: Note, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        var out = "# \(note.title)\n\n"
        let minutes = max(1, Int((note.duration / 60).rounded()))
        out += "_\(formatter.string(from: note.start)) · \(minutes) min_"
        if !note.speakers.isEmpty {
            out += "  \n_" + note.speakers.map(\.name).joined(separator: ", ") + "_"
        }
        out += "\n\n"
        if let summary = note.summary, !summary.isEmpty {
            out += "## \(String(localized: "Summary"))\n\n\(summary)\n\n"
        }
        if !note.keyPoints.isEmpty {
            out += "## \(String(localized: "Key points"))\n\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !note.todos.isEmpty {
            out += "## \(String(localized: "To-dos"))\n\n"
            out += note.todos.map { todo in
                var line = "- [\(todo.done ? "x" : " ")] \(todo.text)"
                let extra = [todo.owner, todo.due].compactMap { $0 }.filter { !$0.isEmpty }
                if !extra.isEmpty { line += " (\(extra.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n") + "\n\n"
        }
        if !note.lines.isEmpty {
            out += "## \(String(localized: "Transcript"))\n\n"
            out += note.lines.map { "**\(note.name(of: $0.speaker))** (\(clock($0.start))): \($0.text)" }
                .joined(separator: "\n\n") + "\n"
        }
        return out
    }

    /// 75 → "1:15", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// When the audio not transcribed yet is ready to go to the recognizer: once it
/// is a few seconds long and ends on a pause (or has grown too long to wait).
/// Silent stretches are dropped without a word.
enum NoteChunker {
    enum Decision: Equatable { case wait, cut, drop }

    static let minSeconds = 4.0
    static let maxSeconds = 18.0
    static let pauseRMS: Float = 0.012
    static let silenceRMS: Float = 0.004

    static func decide(seconds: Double, tailRMS: Float, rms: Float, force: Bool) -> Decision {
        guard seconds >= (force ? 0.5 : minSeconds) else { return .wait }
        guard force || tailRMS < pauseRMS || seconds >= maxSeconds else { return .wait }
        return rms < silenceRMS ? .drop : .cut
    }
}
