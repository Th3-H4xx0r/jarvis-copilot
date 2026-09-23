import Foundation

/// Which voices were speaking, frame by frame, as the on-device diarizer
/// (Sortformer) heard them. Up to four slots; a slot is one voice for as long
/// as the recording runs, and several can be active in the same frame.
struct LiveSpeakerActivity: Equatable, Sendable {
    /// Where frame 0 sits on the session's audio clock.
    var startMs: Int
    var frameMs: Int
    /// `frames[i][slot]`: how sure the diarizer is that `slot` speaks in frame `i`.
    var frames: [[Float]]

    var slotCount: Int { frames.first?.count ?? 0 }

    /// The mean probability of `slot` over a stretch — at least one frame, so
    /// a word shorter than a frame still gets an answer.
    func mean(slot: Int, fromMs: Int, toMs: Int) -> Float {
        guard frameMs > 0, !frames.isEmpty, slot < slotCount else { return 0 }
        let first = max(0, (fromMs - startMs) / frameMs)
        let last = min(frames.count - 1, max(first, (toMs - startMs - 1) / frameMs))
        guard first <= last, first < frames.count else { return 0 }
        let total = (first...last).reduce(Float(0)) { $0 + frames[$1][slot] }
        return total / Float(last - first + 1)
    }
}

/// A run of one line's words spoken by one voice.
struct LiveLinePiece: Equatable, Sendable {
    var words: [SpeechWord]
    /// The diarizer's voice slot, or nil when it heard nobody.
    var slot: Int?

    var startMs: Int { words.first?.startMs ?? 0 }
    var endMs: Int { words.last?.endMs ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }
}

/// Cutting one committed line where the speaker changes.
///
/// Apple's recogniser writes one line for everything it heard between two
/// pauses, and one line gets one voiceprint — so when he spoke over a video,
/// his "Hello, are you there?" was filed under the video's speaker (measured:
/// a 9 s line, the video's voice throughout, his for 1.7 s of it). The
/// diarizer on the same audio hears both voices; this puts each word with the
/// voice that said it.
enum LiveSpeakerSplit {
    /// A slot counts as speaking during a word at this mean probability.
    static let activeAt: Float = 0.5
    /// A piece shorter than this is folded into its neighbour: a cut on a
    /// fragment that brief is more likely the diarizer's jitter than a turn.
    static let minPieceMs = 400

    /// `activity` should cover the line's whole audio window, from the moment
    /// it opened to the moment it closed.
    static func pieces(of words: [SpeechWord], activity: LiveSpeakerActivity?) -> [LiveLinePiece] {
        guard !words.isEmpty else { return [] }
        guard let activity, activity.slotCount > 0 else {
            return [LiveLinePiece(words: words, slot: nil)]
        }
        // How present each voice is across the line's whole audio — the span
        // `activity` covers, not just where the words are: Apple may have
        // written only the voice on top, and across those words alone both
        // voices are equally present. The one running through all of it is the
        // backdrop to a word it shares with another.
        let activityEnd = activity.startMs + activity.frames.count * activity.frameMs
        let presence = (0..<activity.slotCount).map {
            activity.mean(slot: $0, fromMs: activity.startMs, toMs: activityEnd)
        }
        let candidates: [[Int]] = words.map { word in
            (0..<activity.slotCount).filter {
                activity.mean(slot: $0, fromMs: word.startMs,
                              toMs: max(word.endMs, word.startMs + activity.frameMs)) >= activeAt
            }
        }
        let clear: [Int?] = candidates.map { $0.count == 1 ? $0[0] : nil }

        // A word several voices shared, or nobody's, goes with the nearest word
        // only one voice said — the one before it first, as speech runs on. With
        // no such word in the line at all, it goes to the voice least present
        // across the line: the one speaking over the backdrop, not the backdrop.
        var slots: [Int?] = clear
        for index in words.indices where clear[index] == nil {
            let allowed = candidates[index]
            func fits(_ slot: Int) -> Bool { allowed.isEmpty || allowed.contains(slot) }
            let before = words.indices.reversed().lazy
                .filter { $0 < index }.compactMap { clear[$0] }.first(where: fits)
            let after = words.indices.lazy
                .filter { $0 > index }.compactMap { clear[$0] }.first(where: fits)
            if let neighbour = before ?? after {
                slots[index] = neighbour
            } else if !allowed.isEmpty {
                slots[index] = allowed.min { presence[$0] < presence[$1] }
            }
        }

        var pieces: [LiveLinePiece] = []
        for (word, slot) in zip(words, slots) {
            if let tail = pieces.last, tail.slot == slot {
                pieces[pieces.count - 1].words.append(word)
            } else {
                pieces.append(LiveLinePiece(words: [word], slot: slot))
            }
        }
        return fold(pieces)
    }

    /// The stretches of `fromMs...toMs`, in session ms, where `slot` speaks
    /// and nobody else does — the audio a voiceprint of that voice alone can be
    /// made from. A print of overlapped audio is as much the other voice's.
    static func soloRanges(of slot: Int, in activity: LiveSpeakerActivity,
                           fromMs: Int, toMs: Int) -> [ClosedRange<Int>] {
        guard slot < activity.slotCount, activity.frameMs > 0 else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for (index, frame) in activity.frames.enumerated() {
            let start = activity.startMs + index * activity.frameMs
            let end = start + activity.frameMs
            guard end > fromMs, start < toMs else { continue }
            let alone = frame[slot] >= activeAt
                && frame.indices.allSatisfy { $0 == slot || frame[$0] < activeAt }
            guard alone else { continue }
            let clipped = max(start, fromMs)...min(end, toMs)
            if let last = ranges.last, last.upperBound >= clipped.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound...clipped.upperBound
            } else {
                ranges.append(clipped)
            }
        }
        return ranges
    }

    /// Fold pieces too brief to be a turn into their longer neighbour, and
    /// join neighbours that end up with the same voice.
    private static func fold(_ pieces: [LiveLinePiece]) -> [LiveLinePiece] {
        var out = pieces
        while out.count > 1,
              let index = out.indices.first(where: { out[$0].endMs - out[$0].startMs < minPieceMs }) {
            let piece = out.remove(at: index)
            let previousLength = index > 0 ? out[index - 1].endMs - out[index - 1].startMs : -1
            let nextLength = index < out.count ? out[index].endMs - out[index].startMs : -1
            if previousLength >= nextLength {
                out[index - 1].words += piece.words
            } else {
                out[index].words = piece.words + out[index].words
            }
            var joined: [LiveLinePiece] = []
            for next in out {
                if let tail = joined.last, tail.slot == next.slot {
                    joined[joined.count - 1].words += next.words
                } else {
                    joined.append(next)
                }
            }
            out = joined
        }
        return out
    }
}
