import Foundation

extension VoiceStore {
    /// The sound half of barge-in, with no audio stack attached: is something louder than the
    /// reply's own echo being said over it, for long enough? (Whether it is *words* is the
    /// recogniser's check, in VoiceStore.) The tuning lives on VoiceStore (`bargeIn*`).
    struct BargeInDetector {
        /// The last `bargeInWindowMs` of mic frames under the reply: duration and
        /// whether each counted as voiced.
        private(set) var frames: [(ms: Int, voiced: Bool, amp: Double)] = []
        /// Recent mic frames under the reply, for the echo level.
        private(set) var echoFrames: [(ms: Int, amp: Double)] = []

        var voicedMs: Int { frames.reduce(0) { $0 + ($1.voiced ? $1.ms : 0) } }
        var lastVoiced: Bool { frames.last?.voiced ?? false }

        /// What the mic hears under the reply when nobody is talking: the reply's
        /// leftover echo. See `bargeInEchoPercentile`.
        var echoFloor: Double {
            guard echoFrames.reduce(0, { $0 + $1.ms }) >= VoiceStore.bargeInEchoMinMs else { return 0 }
            let sorted = echoFrames.map(\.amp).sorted()
            return sorted[Int(Double(sorted.count - 1) * VoiceStore.bargeInEchoPercentile)]
        }

        /// The level a frame has to reach to count as voiced over the reply.
        var bar: Double { max(VoiceStore.bargeInSpeechAmp, echoFloor * VoiceStore.bargeInEchoMargin) }

        /// A frame that is the reply's echo for sure (the canceller still settling).
        mutating func noteEcho(_ amp: Double, frameMs: Int) {
            echoFrames.append((frameMs, amp))
            var total = echoFrames.reduce(0) { $0 + $1.ms }
            while total > VoiceStore.bargeInEchoWindowMs, echoFrames.count > 1 {
                total -= echoFrames.removeFirst().ms
            }
        }

        /// One mic frame under the reply; true once voiced audio fills `bargeInSustainMs` of the
        /// window. With `learning` off (a sound being checked or waited out — the reply is
        /// turned down then, or the sound is not the reply at all) nothing moves the echo level.
        mutating func feed(_ amp: Double, frameMs: Int, learning: Bool) -> Bool {
            let voiced = amp >= bar
            // A frame under the bar teaches the echo level at once. A frame over it
            // waits until it leaves the decision window: while it is in the window
            // it may be the user's first words, and counting those as echo lifted
            // the bar past the voice trying to clear it. Once it has aged out
            // without triggering, it was the reply — kept out for good instead, a
            // reply that grew louder never raised the bar and interrupted itself.
            if !voiced, learning { noteEcho(amp, frameMs: frameMs) }
            frames.append((frameMs, voiced, amp))
            var total = frames.reduce(0) { $0 + $1.ms }
            while total > VoiceStore.bargeInWindowMs, frames.count > 1 {
                let aged = frames.removeFirst()
                total -= aged.ms
                if aged.voiced, learning { noteEcho(aged.amp, frameMs: aged.ms) }
            }
            return voicedMs >= VoiceStore.bargeInSustainMs
        }

        mutating func reset() {
            frames.removeAll()
            echoFrames.removeAll()
        }
    }
}
