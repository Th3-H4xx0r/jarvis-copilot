import Foundation

/// Everything one voice said in one language until someone else spoke — or
/// they switched language — read as one block.
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

    /// The language this turn is in: its first labelled line's. Nil while no
    /// line carries a label.
    var language: String? { lines.lazy.compactMap(LiveTurns.language).first }

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

    /// The turn in the reader's language: its lines' translations, in order.
    /// Nil when nothing in it has been translated — a turn in your own
    /// language needs no second paragraph. A line still waiting for its
    /// translation is left out until it arrives, rather than shown untranslated
    /// in the translation.
    func readerText(primary: String) -> String? {
        let parts = lines.compactMap { line -> String? in
            let translation = (line.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return translation.isEmpty ? nil : translation
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
                // Same voice, same language, and not a two-minute silence: the
                // turn goes on, even past a note that arrived in the middle of
                // it — the note stays after everything this turn says. A switch
                // of language starts a new block, so each block has one
                // language tag and a translation that matches it.
                if var turn = open, speakerKey(line) == turn.speakerKey,
                   sameLanguage(line, turn),
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

    /// A line's language for grouping — its primary subtag, so `en-US` and
    /// `en` are one language — or nil when it carries no label.
    static func language(_ line: LiveSegment) -> String? {
        let tag = subtag(line.lang)
        return tag.isEmpty ? nil : tag
    }

    /// An unlabelled line, or a turn with no label yet, goes with anything:
    /// there is no language on it to disagree about.
    static func sameLanguage(_ line: LiveSegment, _ turn: LiveTurn) -> Bool {
        guard let mine = language(line), let theirs = turn.language else { return true }
        return mine == theirs
    }

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
