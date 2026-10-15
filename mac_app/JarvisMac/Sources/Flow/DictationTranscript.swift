import Foundation

/// The words of one dictation, kept whole when Apple's recognizer loses some of
/// them (Tests/FlowTests.swift).
///
/// On a long dictation the recognizer can start over after a pause (the next
/// result holds only the new words) or drop a stretch it already gave. Taken as
/// is, either loses what was said, so each result is merged with the words seen
/// before: a result that looks like a fresh start closes the text so far, and a
/// word heard earlier that no newer word covers in time is kept where it was.
/// After coucou's DictationTranscript (github.com/Louis-CFM/coucou, MIT).
struct DictationTranscript: Equatable {
    /// One word (or a few) with its place in the audio, in seconds.
    struct Piece: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    private(set) var committed = ""
    private(set) var pieces: [Piece] = []
    private(set) var current = ""

    var text: String { Self.join(committed, current) }

    /// A newer word closer than this to an older one, in time, replaces it.
    static let tolerance = 0.25

    mutating func absorb(_ formatted: String, pieces new: [Piece]) {
        if Self.isRestart(previous: current, new: formatted) {
            committed = Self.join(committed, current)
            pieces = new
            current = formatted
            return
        }
        let timed = !new.isEmpty && new.contains { $0.end > $0.start }
        guard timed, let last = new.last else {
            pieces = new
            current = formatted
            return
        }
        let kept = pieces.filter { old in
            old.end > old.start
                && old.end <= last.start + Self.tolerance
                && !new.contains { Self.close(old, $0) }
        }
        let alreadySaid = !kept.isEmpty
            && Self.normalized(formatted).contains(Self.normalized(kept.map(\.text).joined(separator: " ")))
        if kept.isEmpty || alreadySaid {
            pieces = new
            current = formatted
        } else {
            pieces = (kept + new).sorted { $0.start < $1.start }
            current = pieces.map(\.text).joined(separator: " ")
        }
    }

    mutating func absorb(_ formatted: String) { absorb(formatted, pieces: []) }

    /// A fresh start: the text so far had a few words, the new one has less than
    /// half as many and does not start with the same word.
    static func isRestart(previous: String, new: String) -> Bool {
        let p = previous.split(whereSeparator: \.isWhitespace)
        let n = new.split(whereSeparator: \.isWhitespace)
        guard p.count >= 3, !n.isEmpty, n.count * 2 <= p.count else { return false }
        return p[0].lowercased() != n[0].lowercased()
    }

    static func normalized(_ s: String) -> String {
        let kept = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func close(_ a: Piece, _ b: Piece) -> Bool {
        a.start < b.end + tolerance && b.start < a.end + tolerance
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
