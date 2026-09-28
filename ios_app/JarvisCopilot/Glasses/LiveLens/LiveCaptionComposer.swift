import Foundation

struct LiveCaptionSegment: Equatable {
    var seq: Int
    var name: String
    var text: String
    var translation: String
}

/// What the lens needs from Live at one moment: the words being spoken now (no
/// speaker yet) and the most recent finished lines.
struct LiveCaptionSnapshot: Equatable {
    var partial: String
    var segments: [LiveCaptionSegment]
    /// Live's session id: a new session numbers its lines from 1 again.
    var session: String = ""
}

struct LensCaption: Equatable {
    var text: String
    var translation: String
    var final: Bool
}

/// Live's transcript → lens captions. Finished lines go up named ("Maya: …"),
/// the words being spoken go up unnamed until their line lands, a late
/// translation re-sends its line once, and nothing is sent twice.
struct LiveCaptionComposer {
    static let maxChars = 120

    private var baseline = 0
    private var sent: [Int: (text: String, translation: String)] = [:]
    private var lastPartial = ""
    private var session = ""
    /// The line on the lens now: only it may be re-sent (a late translation for
    /// an older line would put that older line back up).
    private var lastShownSeq = 0

    /// Starts (or restarts) showing: remembers what already happened so the
    /// backlog is not replayed, and returns the one line to put up now.
    mutating func begin(_ s: LiveCaptionSnapshot) -> LensCaption? {
        let segments = s.segments.sorted { $0.seq < $1.seq }
        session = s.session
        baseline = segments.last?.seq ?? 0
        lastShownSeq = baseline
        sent = [:]
        for segment in segments { sent[segment.seq] = (segment.text, segment.translation) }
        let partial = s.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartial = partial
        if !partial.isEmpty, partial != segments.last?.text {
            return LensCaption(text: Self.fit(partial), translation: "", final: false)
        }
        return segments.last.map(Self.caption)
    }

    mutating func update(_ s: LiveCaptionSnapshot) -> [LensCaption] {
        var out: [LensCaption] = []
        let segments = s.segments.sorted { $0.seq < $1.seq }
        // A new session, or a transcript that started over, numbers from 1 again:
        // everything it holds is new.
        if s.session != session || (segments.last?.seq ?? 0) < baseline {
            session = s.session
            baseline = 0
            lastShownSeq = 0
            sent = [:]
        }
        for segment in segments where segment.seq > baseline || sent[segment.seq] != nil {
            if let previous = sent[segment.seq] {
                if previous.text == segment.text, previous.translation == segment.translation { continue }
                sent[segment.seq] = (segment.text, segment.translation)
                // Only the line still on the lens is re-sent.
                guard segment.seq == lastShownSeq else { continue }
            } else {
                sent[segment.seq] = (segment.text, segment.translation)
                lastShownSeq = max(lastShownSeq, segment.seq)
            }
            out.append(Self.caption(segment))
        }
        if sent.count > 64, let cutoff = sent.keys.sorted().dropLast(64).last {
            sent = sent.filter { $0.key > cutoff }
        }
        let partial = s.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial.isEmpty {
            lastPartial = ""
        } else if partial != lastPartial {
            lastPartial = partial
            // The words Live just committed come back as the committing echo; the
            // final line already shows them.
            if partial != segments.last?.text {
                out.append(LensCaption(text: Self.fit(partial), translation: "", final: false))
            }
        }
        return out
    }

    /// The name stays whole; only the words are trimmed to fit.
    static func caption(_ segment: LiveCaptionSegment) -> LensCaption {
        let name = segment.name + ": "
        return LensCaption(text: name + fit(segment.text, max: maxChars - name.count),
                           translation: fit(segment.translation), final: true)
    }

    /// At most `max` characters: the most recent words, "…" in front.
    static func fit(_ text: String, max: Int = maxChars) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        var tail = String(trimmed.suffix(Swift.max(1, max - 1)))
        if let space = tail.firstIndex(of: " ") { tail = String(tail[tail.index(after: space)...]) }
        return "…" + tail
    }
}
