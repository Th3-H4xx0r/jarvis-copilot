import Foundation

/// Sequential playback of assistant audio clips. Port of `voice/audio_queue.dart`.
///
/// The voice backend hands us either MP3 segments (quality mode, and the realtime
/// MP3 fallback) or raw 24 kHz PCM-S16LE frames (realtime). Two paths:
///
///  • **Gapless stream** (preferred, plan 1.7) — realtime PCM does NOT wait for a
///    whole segment: `appendPcm` feeds one continuous render stream, so the first
///    ~160 ms plays while the rest of the sentence is still arriving. Karaoke
///    timing is derived from bytes fed + wall clock.
///  • **Clip queue** (fallback + every MP3) — clips play back-to-back; PCM is cut
///    by a `PcmChunker` and wrapped in a WAV header.
///
/// `onIdle` fires when the queue drains (so the store can return to
/// listening/idle); `onAmplitude` drives the orb during playback.
@MainActor
final class AudioQueue {

    // MARK: - Callbacks

    var onIdle: (() -> Void)?
    var onAmplitude: ((Double) -> Void)?
    var onPlaybackStart: (() -> Void)?
    /// A tagged clip began, with the clip's playback duration in ms (exact for
    /// PCM, the running segment total on the streaming path). `tag` is the
    /// caller's karaoke segment id.
    var onClipStart: ((Int?, Int) -> Void)?
    /// The current clip's playback position in ms.
    var onPosition: ((Int?, Int) -> Void)?

    // MARK: - Tuning

    /// Karaoke position cadence on the streaming path.
    static let nativeTickMs = 100
    /// Wait for the last buffer to drain before going idle.
    static let nativeIdleGraceMs = 120
    /// Safety net: if `audio_end` never arrives (dropped frame, server error) go
    /// idle once everything fed has played and nothing new came for this long.
    static let nativeStallIdleMs = 1500

    // MARK: - Dependencies

    private let output: AudioOutput
    private let clock: VoiceClock

    // MARK: - Clip queue state

    private struct Clip {
        let bytes: Data
        let ext: String
        /// Caller's segment id, for karaoke highlight sync.
        let tag: Int?
        /// Exact for PCM; nil for MP3 (the decoder tells us at play time).
        let durationMs: Int?
        /// Total audio of `tag` emitted so far, including this clip. Only set on
        /// the streaming-fallback path; nil means "this clip IS the whole segment".
        let segmentMs: Int?
        /// Audio of `tag` played by EARLIER clips — added to every position
        /// report so the word highlight is continuous across a split segment.
        let baseMs: Int
    }

    private var queue: [Clip] = []
    private var playing = false
    private var stopped = false
    /// Tag of the clip currently playing (for position events).
    private var currentTag: Int?
    /// Ms of this tag's audio played by earlier chunks.
    private var currentClipBaseMs = 0
    /// An MP3 clip waiting for its real decoded duration.
    ///
    /// The player can report the duration from INSIDE `play()` — before we have
    /// announced the estimate — so the correction is buffered and applied strictly
    /// after it, or the estimate would overwrite the good schedule.
    private struct DurationCorrection {
        let tag: Int
        var estimateAnnounced = false
        var durationMs: Int?
    }
    private var correction: DurationCorrection?
    /// Streaming cutter for the realtime PCM fallback.
    private var chunker: PcmChunker?

    // MARK: - Gapless stream state

    private var nativeActive = false
    /// `audio_end` seen; go idle once playback catches up.
    private var nativeEnded = false
    /// Segment currently being fed.
    private var nativeTag: Int?
    /// Total audio handed to the player this stream.
    private var nativeFedMs = 0
    /// Fed ms when the current segment began.
    private var nativeSegBaseMs = 0
    private var nativeStart: Date?
    private var nativeTick: VoiceTimerToken?
    /// A feed is queued on the chain but has not yet run.
    private var nativePending = false
    private var nativeLastFeed: Date?

    // MARK: - Serialised async work
    // One chain for both paths so `startStream`/`feed`/`play` can never
    // interleave — out-of-order audio is the one failure you would hear.

    private var chain: Task<Void, Never>?
    private var chainSeq = 0
    /// Bumped by `stop`/`dispose` so work already queued becomes a no-op.
    private var epoch = 0

    init(output: AudioOutput, clock: VoiceClock) {
        self.output = output
        self.clock = clock

        output.onClipComplete = { [weak self] in self?.advance() }
        output.onClipPosition = { [weak self] pos in
            guard let self, let tag = self.currentTag else { return }
            // Positions are reported SEGMENT-relative: a segment split into
            // several streamed chunks must still advance one continuous word
            // schedule, so we add the audio already played by earlier chunks.
            self.onPosition?(tag, Int(pos * 1000) + self.currentClipBaseMs)
        }
        output.onClipDuration = { [weak self] dur in
            guard let self, var pending = self.correction, dur > 0 else { return }
            // MP3 duration isn't known at play() time, so we re-fire onClipStart
            // with the REAL duration once it lands. The store treats a repeat tag
            // as a schedule correction, not a restart.
            let ms = Int(dur * 1000)
            if pending.estimateAnnounced {
                self.correction = nil
                self.onClipStart?(pending.tag, ms)
            } else {
                pending.durationMs = ms
                self.correction = pending
            }
        }
    }

    // MARK: - Public state

    var isBusy: Bool { playing || !queue.isEmpty || nativeActive }

    /// True while a segment is mid-stream (some audio buffered but not emitted).
    var hasPendingPcm: Bool { nativeActive || (chunker?.bufferedBytes ?? 0) > 0 }

    // MARK: - Enqueue

    /// Enqueue an MP3 clip (raw bytes). `tag` (a segment id) lets the caller sync
    /// a word highlight to this clip's playback.
    func enqueueMp3(_ bytes: Data, tag: Int? = nil) {
        guard !bytes.isEmpty else { return }
        enqueue(Clip(bytes: bytes, ext: "mp3", tag: tag,
                     durationMs: nil, segmentMs: nil, baseMs: 0))
    }

    /// Enqueue a whole raw PCM-S16LE clip at `sampleRate` (mono), wrapped in a
    /// WAV container. PCM duration is exact (computed from the byte count).
    func enqueuePcm(_ pcm: Data, sampleRate: Int = 24000, tag: Int? = nil) {
        guard !pcm.isEmpty else { return }
        let durMs = (pcm.count / 2) * 1000 / sampleRate
        enqueue(Clip(bytes: Self.wrapWav(pcm, sampleRate: sampleRate), ext: "wav",
                     tag: tag, durationMs: durMs, segmentMs: nil, baseMs: 0))
    }

    /// Stream realtime PCM for segment `tag` as it arrives. Plays the leading
    /// slice as soon as there's enough of it instead of waiting for the segment
    /// to finish. Call `endPcmSegment` when `audio_end` lands.
    func appendPcm(_ pcm: Data, sampleRate: Int = 24000, tag: Int? = nil) {
        guard !stopped, !pcm.isEmpty else { return }
        if output.isStreamAvailable, queue.isEmpty, !(playing && !nativeActive) {
            appendNative(pcm, sampleRate: sampleRate, tag: tag)
            return
        }
        for chunk in chunkerFor(sampleRate).add(pcm, tag: tag) { enqueueChunk(chunk) }
    }

    /// The segment is complete — play whatever is left of it.
    func endPcmSegment(tag: Int? = nil) {
        guard !stopped else { return }
        if nativeActive || (output.isStreamAvailable && nativePending) {
            // Ordered behind the feeds already queued: a short reply's audio_end
            // can land before the first feed has even opened the stream, and
            // marking "ended" ahead of that feed would be overwritten by it.
            let ep = epoch
            serial { [weak self] in
                guard let self, ep == self.epoch, self.nativeActive else { return }
                self.nativeEnded = true
            }
            return
        }
        guard let chunker else { return }
        for chunk in chunker.flush(tag: tag) { enqueueChunk(chunk) }
    }

    /// Drop anything queued and stop playback immediately (barge-in / new turn).
    /// Does NOT fire `onIdle`.
    func stop() async {
        epoch += 1
        // The per-frame chain is only ever as long as the audio still to play;
        // dropping it here stops a barge-in paying for the whole interrupted
        // sentence, and stops the last task being retained until the next one.
        chain?.cancel()
        chain = nil
        queue.removeAll()
        playing = false
        currentTag = nil
        currentClipBaseMs = 0
        correction = nil
        // Barge-in/new turn: drop half-assembled audio too, or the tail of the
        // interrupted sentence would play after the user has moved on.
        chunker?.reset()
        if nativeActive {
            await output.flushStream()
            finishNative(fireIdle: false)
        }
        await output.stopClip()
        onAmplitude?(0)
    }

    func dispose() async {
        stopped = true
        epoch += 1
        chain?.cancel()
        chain = nil
        nativeTick?.cancel()
        nativeTick = nil
        queue.removeAll()
        chunker?.reset()
        await output.stopStream()
        await output.stopClip()
    }

    /// Tests only: wait until every queued async step has run (a step may queue
    /// more, so we drain until the chain stops growing).
    func settle() async {
        var last = -1
        for _ in 0..<64 {
            if chainSeq == last { return }
            last = chainSeq
            await chain?.value
        }
    }

    // MARK: - Gapless stream path

    private func appendNative(_ pcm: Data, sampleRate: Int, tag: Int?) {
        let ms = (pcm.count / 2) * 1000 / sampleRate
        nativePending = true
        let ep = epoch
        serial { [weak self] in
            guard let self else { return }
            self.nativePending = false
            guard !self.stopped, ep == self.epoch else { return }
            if !self.nativeActive {
                guard await self.output.startStream(sampleRate: sampleRate) else {
                    // The player refused — hand this chunk to the fallback path.
                    for chunk in self.chunkerFor(sampleRate).add(pcm, tag: tag) {
                        self.enqueueChunk(chunk)
                    }
                    return
                }
                self.nativeActive = true
                self.nativeEnded = false
                self.playing = true
                self.nativeFedMs = 0
                self.nativeSegBaseMs = 0
                self.nativeStart = nil
                self.nativeTag = tag
            }
            if tag != self.nativeTag {
                // Next sentence in the same stream: positions restart at its base.
                self.nativeSegBaseMs = self.nativeFedMs
                self.nativeTag = tag
                self.currentClipBaseMs = 0
            }
            self.nativeEnded = false
            await self.output.feed(pcm)
            guard ep == self.epoch else { return }
            self.nativeFedMs += ms
            self.nativeLastFeed = self.clock.now
            if self.nativeStart == nil {
                self.nativeStart = self.clock.now
                self.currentTag = tag
                self.onPlaybackStart?()
                self.onAmplitude?(0.6) // coarse "speaking" pulse for the orb
                self.armNativeTick()
            }
            self.currentTag = tag
            // Running total for this segment so the karaoke schedule stretches as
            // more of the sentence arrives (a repeat tag = schedule correction).
            self.onClipStart?(tag, self.nativeFedMs - self.nativeSegBaseMs)
        }
    }

    private func armNativeTick() {
        nativeTick?.cancel()
        nativeTick = clock.schedule(after: Self.nativeTickMs) { [weak self] in
            self?.nativeTickFired()
        }
    }

    private func nativeTickFired() {
        nativeTick = nil
        guard nativeActive, let start = nativeStart else { return }
        let elapsed = Int(clock.now.timeIntervalSince(start) * 1000)
        let played = min(max(elapsed, 0), nativeFedMs)
        if let tag = nativeTag { onPosition?(tag, played - nativeSegBaseMs) }
        if nativeEnded, elapsed >= nativeFedMs + Self.nativeIdleGraceMs {
            finishNative(fireIdle: true)
            return
        }
        if !nativePending, let last = nativeLastFeed,
           elapsed >= nativeFedMs + Self.nativeStallIdleMs,
           Int(clock.now.timeIntervalSince(last) * 1000) >= Self.nativeStallIdleMs {
            // No audio_end — idle after the stall rather than hanging in "speaking".
            finishNative(fireIdle: true)
            return
        }
        armNativeTick()
    }

    private func finishNative(fireIdle: Bool) {
        nativeTick?.cancel()
        nativeTick = nil
        nativeActive = false
        nativeEnded = false
        nativeStart = nil
        nativeLastFeed = nil
        nativeTag = nil
        currentTag = nil
        playing = false
        let ep = epoch
        serial { [weak self] in
            guard let self, ep == self.epoch else { return }
            await self.output.stopStream()
        }
        onAmplitude?(0)
        if fireIdle { onIdle?() }
    }

    // MARK: - Clip queue path

    private func chunkerFor(_ sampleRate: Int) -> PcmChunker {
        if let existing = chunker, existing.sampleRate == sampleRate { return existing }
        let fresh = PcmChunker(sampleRate: sampleRate)
        chunker = fresh
        return fresh
    }

    private func enqueueChunk(_ chunk: PcmChunk) {
        guard !chunk.bytes.isEmpty else { return }
        enqueue(Clip(bytes: Self.wrapWav(chunk.bytes, sampleRate: chunk.sampleRate),
                     ext: "wav",
                     tag: chunk.tag,
                     durationMs: chunk.durationMs,
                     // Announce the segment's running total, not this slice's
                     // length, so the karaoke schedule stretches as more of the
                     // sentence arrives.
                     segmentMs: chunk.segmentMsSoFar,
                     baseMs: chunk.segmentMsSoFar - chunk.durationMs))
    }

    private func enqueue(_ clip: Clip) {
        guard !stopped else { return }
        queue.append(clip)
        if !playing { advance() }
    }

    private func advance() {
        guard !stopped else { return }
        if queue.isEmpty {
            if playing {
                playing = false
                onAmplitude?(0)
                onIdle?()
            }
            return
        }
        playing = true
        let clip = queue.removeFirst()
        let ep = epoch
        serial { [weak self] in
            guard let self, ep == self.epoch else { return }
            // Drop position events while we swap clips so a trailing event from
            // the outgoing clip isn't attributed to the incoming one.
            self.currentTag = nil
            // Armed BEFORE play(), because play() may report the duration itself.
            self.correction = (clip.durationMs == nil ? clip.tag : nil)
                .map { DurationCorrection(tag: $0) }
            await self.output.stopClip()
            guard ep == self.epoch else { return }
            guard await self.output.play(clip.bytes, fileExtension: clip.ext) else {
                self.advance() // skip a bad clip rather than wedging the queue
                return
            }
            guard ep == self.epoch else { return }
            self.currentTag = clip.tag
            self.currentClipBaseMs = clip.baseMs
            self.onPlaybackStart?()
            self.onAmplitude?(0.6)
            guard clip.tag != nil else { return }
            if let dur = clip.durationMs {
                // PCM: exact duration, schedule the karaoke immediately. For a
                // streamed segment we report the running TOTAL so far.
                self.onClipStart?(clip.tag, clip.segmentMs ?? dur)
            } else {
                // MP3: start on an estimate now (so the segment is current and
                // words can advance), then correct with the real duration.
                self.onClipStart?(clip.tag, 0)
                self.correction?.estimateAnnounced = true
                if let pending = self.correction, let ms = pending.durationMs {
                    self.correction = nil
                    self.onClipStart?(pending.tag, ms)
                }
            }
        }
    }

    private func serial(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chainSeq += 1
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: - WAV

    /// Minimal 44-byte PCM WAV header + samples.
    static func wrapWav(_ pcm: Data, sampleRate: Int) -> Data {
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var out = Data(capacity: 44 + pcm.count)
        func str(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) {
            let u = UInt32(truncatingIfNeeded: v)
            out.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF),
                                    UInt8((u >> 16) & 0xFF), UInt8((u >> 24) & 0xFF)])
        }
        func u16(_ v: Int) {
            let u = UInt16(truncatingIfNeeded: v)
            out.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF)])
        }
        str("RIFF"); u32(36 + pcm.count); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(pcm.count)
        out.append(pcm)
        return out
    }
}
