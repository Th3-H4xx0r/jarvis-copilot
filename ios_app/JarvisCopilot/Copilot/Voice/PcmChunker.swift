import Foundation

/// One playable slice of a reply segment.
struct PcmChunk: Equatable, Sendable {
    let bytes: Data
    let sampleRate: Int
    /// The karaoke segment this audio belongs to (see `VoiceSegment`).
    let tag: Int?
    /// This slice's own duration.
    let durationMs: Int
    /// Total audio emitted for `tag` INCLUDING this slice — the store
    /// re-schedules the word highlight against this growing total, which is why
    /// splitting a segment doesn't strand the highlight on the first word.
    let segmentMsSoFar: Int
    /// True for the last slice of a segment.
    let isSegmentEnd: Bool
}

/// Cuts an arriving PCM-S16LE reply stream into playable pieces so the first
/// sample is audible while the rest of the sentence is still on the wire
/// (plan 1.7). Direct port of `voice/pcm_chunker.dart`.
///
/// Pure: the chunker only decides WHERE to cut, which makes the ordering
/// guarantee (the one thing that would be audible if it broke) unit-testable.
final class PcmChunker {

    /// Reply PCM sample rate (mono). Only used to convert bytes → milliseconds.
    let sampleRate: Int

    init(sampleRate: Int) { self.sampleRate = sampleRate }

    // MARK: - Cut sizes (plan 1.7)

    /// How much audio to gather before the FIRST clip of a segment. Small on
    /// purpose — this length IS the added first-word latency. 160 ms is enough
    /// for the player to have decodable audio and to survive a jittery link.
    static let firstChunkMs = 160

    /// Steady-state clip length once playback is running. Larger than the first
    /// chunk because by then we're ahead of the speaker: bigger clips mean fewer
    /// buffer swaps (each swap is a potential seam).
    static let chunkMs = 500

    private var currentTag: Int?
    private var buf = Data()
    /// Clips already emitted for the current segment.
    private var emittedForTag = 0
    /// Total ms emitted for the current segment.
    private var segmentMs = 0

    /// Bytes currently held back (not yet long enough to emit).
    var bufferedBytes: Int { buf.count }

    /// Feed newly-arrived PCM for segment `tag`; returns whatever is now long
    /// enough to play, in arrival order.
    func add(_ bytes: Data, tag: Int?) -> [PcmChunk] {
        if tag != currentTag { startSegment(tag) }
        if !bytes.isEmpty { buf.append(bytes) }
        var out: [PcmChunk] = []
        while true {
            let want = bytesFor(emittedForTag == 0 ? Self.firstChunkMs : Self.chunkMs)
            if buf.count < want { break }
            out.append(take(want, segmentEnd: false))
        }
        return out
    }

    /// The segment is complete — emit whatever is left, however short.
    func flush(tag: Int?) -> [PcmChunk] {
        if tag != currentTag { return [] }
        // Drop a dangling half-sample; it can't be played and would desync the
        // next segment's byte stream.
        let usable = buf.count - (buf.count % 2)
        if usable <= 0 {
            buf.removeAll()
            return []
        }
        return [take(usable, segmentEnd: true)]
    }

    /// Barge-in / new turn: throw away everything buffered so stale audio can
    /// never surface after the user has moved on.
    func reset() {
        buf.removeAll()
        currentTag = nil
        emittedForTag = 0
        segmentMs = 0
    }

    private func startSegment(_ tag: Int?) {
        buf.removeAll()
        currentTag = tag
        emittedForTag = 0
        segmentMs = 0
    }

    private func take(_ byteCount: Int, segmentEnd: Bool) -> PcmChunk {
        let n = min(byteCount, buf.count)
        let chunk = Data(buf.prefix(n))
        buf = Data(buf.dropFirst(n))
        let ms = (n / 2) * 1000 / sampleRate
        segmentMs += ms
        emittedForTag += 1
        return PcmChunk(bytes: chunk, sampleRate: sampleRate, tag: currentTag,
                        durationMs: ms, segmentMsSoFar: segmentMs, isSegmentEnd: segmentEnd)
    }

    /// Whole 16-bit frames only — a split sample would click.
    private func bytesFor(_ ms: Int) -> Int { (sampleRate * ms / 1000) * 2 }
}
