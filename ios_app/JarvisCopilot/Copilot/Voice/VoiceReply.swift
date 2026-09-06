import Foundation

/// The assistant's reply as it streams in, plus the karaoke word highlight.
/// Extracted from `voice_controller.dart` (`_segs` / `_appendSpeech` /
/// `_claimSegTag` / `_onClipStart` / `_onClipPosition` / `_recomputeSpoken`)
/// so the highlight can be asserted without any audio.
///
/// Reply text arrives in chunks; each chunk becomes a segment with its own TTS
/// clip. The clip's measured duration drives a word schedule, so the highlight
/// re-syncs to real audio at every segment boundary and drift can't accumulate.
struct VoiceReply: Equatable {

    private(set) var segments: [VoiceSegment] = []
    /// The joined plain (markdown-stripped) reply — what the view renders.
    private(set) var text = ""
    /// How many leading whitespace-delimited words of `text` have been spoken.
    private(set) var spokenWords = 0
    private(set) var totalWords = 0
    /// Index of the segment whose clip is currently playing.
    private(set) var currentSegment = -1

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Clear all reply + highlight state at the start of a new turn.
    mutating func reset() {
        segments.removeAll()
        text = ""
        spokenWords = 0
        totalWords = 0
        currentSegment = -1
    }

    /// Append a chunk of assistant reply text as a new segment. The raw text is
    /// markdown-stripped (so it matches the spoken audio) and split into words.
    /// Returns the new segment's index, or nil when the chunk stripped to
    /// nothing (a code fence, say) — the caller must not tag a clip with it.
    @discardableResult
    mutating func append(_ raw: String) -> Int? {
        let plain = voicePlainSpeech(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let segment = VoiceSegment(plain, wordOffset: totalWords)
        totalWords += segment.words.count
        segments.append(segment)
        text = segments.map(\.text).joined(separator: "\n\n")
        return segments.count - 1
    }

    /// Pair an incoming clip with the most recent text segment that doesn't yet
    /// have audio, so the highlight can time its words against it.
    mutating func claimSegmentTag() -> Int? {
        for i in stride(from: segments.count - 1, through: 0, by: -1) where !segments[i].audioAssigned {
            segments[i].audioAssigned = true
            return i
        }
        return nil
    }

    /// Mark `index` as having a clip (the quality path hands text + audio
    /// together, so it's always the segment just appended).
    mutating func assignAudio(to index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].audioAssigned = true
    }

    /// A segment's TTS clip began — schedule its words across the clip duration
    /// and mark everything before it fully spoken.
    ///
    /// For an MP3 clip this fires TWICE: once with an estimate at play time, then
    /// again with the real decoded duration. The second call is a schedule
    /// CORRECTION for the same segment — it must not reset its progress.
    mutating func clipStarted(tag: Int?, durationMs: Int) {
        guard let tag, segments.indices.contains(tag) else { return }
        for i in 0..<tag { segments[i].localSpoken = segments[i].words.count }
        let isNew = tag != currentSegment
        currentSegment = tag
        var ms = durationMs
        if ms <= 0 { ms = segments[tag].words.count * 300 } // ~200 wpm estimate
        segments[tag].schedule(ms)
        if isNew { segments[tag].localSpoken = 0 }
        recomputeSpoken()
    }

    /// Advance the highlight to match the current clip's playback position.
    mutating func clipPosition(tag: Int?, positionMs: Int) {
        guard let tag, tag == currentSegment, segments.indices.contains(tag) else { return }
        // Drop a stale position event left over from the previous (outgoing)
        // clip: it would read near that clip's end and, since `advance` is
        // monotonic, would jump this segment straight to its last word.
        guard positionMs <= segments[tag].durMs + 300 else { return }
        segments[tag].advance(positionMs)
        recomputeSpoken()
    }

    /// Reply finished — light up any words the position stream didn't reach.
    mutating func finalizeSpoken() { spokenWords = totalWords }

    private mutating func recomputeSpoken() {
        var n = 0
        for i in segments.indices {
            if i < currentSegment {
                n += segments[i].words.count
            } else if i == currentSegment {
                n += segments[i].localSpoken
                break
            } else {
                break
            }
        }
        spokenWords = n
    }
}
