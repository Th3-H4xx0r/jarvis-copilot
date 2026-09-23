import Foundation

/// Everything one voice said until someone else spoke, read as one block.
///
/// A row per committed line put a speaker chip, a clock, a globe and "from
/// Spanish" on every clause a person paused after — five short lines from one
/// speaker filled the screen with headers. A turn has one header, the words as
/// one paragraph, and the translation as one more.
struct LiveTurn: Identifiable, Equatable {
    var lines: [LiveSegment]
    /// Notes the watchers wrote while this turn was the latest thing said.
    /// They sit after it rather than splitting it in two.
    var notes: [LiveInsight] = []

    /// The first line's `seq`: stays put while the turn grows, so SwiftUI keeps
    /// the same view as words are added.
    var id: Int { lines.first?.seq ?? 0 }

    var first: LiveSegment { lines[0] }
    var last: LiveSegment { lines[lines.count - 1] }
    var startMs: Int { first.startMs }
    var endMs: Int { last.endMs }

    var speakerKey: String { LiveTurns.speakerKey(first) }

    /// Unsure while ANY line in it is: a merge can still move one of them.
    var unconfirmed: Bool { lines.contains { $0.labelState == .provisional } }

    var text: String {
        lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func contains(seq: Int) -> Bool { lines.contains { $0.seq == seq } }

    /// The languages in this turn other than the reader's, in the order spoken.
    func foreignLanguages(primary: String) -> [String] {
        var seen = Set<String>()
        return lines.compactMap { line in
            let subtag = LiveTurns.subtag(line.lang)
            guard !subtag.isEmpty, subtag != LiveTurns.subtag(primary),
                  seen.insert(subtag).inserted else { return nil }
            return line.lang
        }
    }

    /// The turn in the reader's language: each line's translation, or the line
    /// itself when it was already in that language. Nil when nothing in it has
    /// been translated — a turn in your own language needs no second paragraph.
    /// A foreign line still waiting for its translation is left out until it
    /// arrives, rather than shown untranslated in the translation.
    func readerText(primary: String) -> String? {
        guard lines.contains(where: { !($0.translation ?? "").isEmpty }) else { return nil }
        let own = LiveTurns.subtag(primary)
        let parts: [String] = lines.compactMap { line in
            if let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty {
                return translation
            }
            let subtag = LiveTurns.subtag(line.lang)
            let foreign = !subtag.isEmpty && subtag != own
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return foreign || text.isEmpty ? nil : text
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One thing in the conversation as the screen lays it out.
enum LiveTimelineItem: Identifiable, Equatable {
    case turn(LiveTurn)
    /// A note from before anyone had spoken.
    case note(LiveInsight)

    var id: String {
        switch self {
        case .turn(let turn): return "t\(turn.id)"
        case .note(let note): return "i\(note.localID)"
        }
    }
}

enum LiveTurns {
    /// A pause this long from the same person starts a new turn anyway: after
    /// two minutes it is a new thought, and its own start time helps.
    static let maxPauseMs = 120_000

    /// Build the turns from the transcript's rows, in order.
    static func timeline(_ rows: [LiveRow]) -> [LiveTimelineItem] {
        var items: [LiveTimelineItem] = []
        var open: LiveTurn?

        for row in rows {
            switch row {
            case .segment(let line):
                // Same voice, and not a two-minute silence: the turn goes on,
                // even past a note that arrived in the middle of it — the note
                // stays after everything this turn says.
                if var turn = open, speakerKey(line) == turn.speakerKey,
                   line.startMs - turn.endMs <= maxPauseMs {
                    turn.lines.append(line)
                    open = turn
                } else {
                    if let turn = open { items.append(.turn(turn)) }
                    open = LiveTurn(lines: [line])
                }
            case .insight(let note):
                if open != nil {
                    open?.notes.append(note)
                } else {
                    items.append(.note(note))
                }
            }
        }
        if let turn = open { items.append(.turn(turn)) }
        return items
    }

    /// Who a line belongs to, for deciding whether it continues a turn. The
    /// server's voice id when there is one; a name otherwise; and lines nobody
    /// has placed yet keep together until identification lands (about a
    /// third of a second later) and regroups them.
    static func speakerKey(_ line: LiveSegment) -> String {
        if let id = line.speakerID, !id.isEmpty { return "id:" + id }
        if let name = line.speakerName, !name.isEmpty { return "name:" + name }
        return unplacedKey
    }

    static let unplacedKey = "unplaced"

    /// `es-419` → `es`. Kept here rather than borrowed from `LiveTranslator`,
    /// whose copy is main-actor isolated.
    static func subtag(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        return String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// How soon after a turn the words being spoken now are taken to continue
    /// it. A guess, and shown as one: the live words stay dimmed until their
    /// line is committed and placed for real.
    static let continuesWithinMs = 10_000

    static func liveContinues(_ turn: LiveTurn, liveStartMs: Int) -> Bool {
        liveStartMs >= turn.startMs && liveStartMs - turn.endMs <= continuesWithinMs
    }
}
