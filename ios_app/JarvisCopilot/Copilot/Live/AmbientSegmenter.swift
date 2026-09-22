import Foundation

/// What one frame of ambient audio did to the current utterance.
enum AmbientSegmentEvent: Equatable, Sendable {
    case none
    /// Speech just began. The store uses this to open an on-device transcription
    /// session, not to send anything.
    case started(atMs: Int)
    /// An utterance finished. `startMs`/`endMs` are ms since capture began and go
    /// straight onto the wire as `ts_start_ms` / `ts_end_ms`.
    case ended(startMs: Int, endMs: Int)
}

/// Utterance segmentation for AMBIENT capture.
///
/// A separate type from `Endpointer` rather than a parameterisation of it, for two
/// reasons that both come from design §5.1:
///
///  * **The thresholds are different by an order of magnitude.** `Endpointer` is
///    calibrated for the user talking into their phone through Apple's voice
///    processing, which applies automatic gain control — ordinary speech lands
///    around 0.02 peak. Ambient capture deliberately runs with that processing OFF
///    (it attenuates exactly the distant speakers this mode exists to hear), so a
///    person across a room arrives several times quieter. Reusing `Endpointer`'s
///    0.012 gate would mean a room full of conversation never opened a single
///    utterance.
///  * **Live needs timestamps and Endpointer has none.** Every `seg` frame carries
///    `ts_start_ms`/`ts_end_ms`, and they must come from the AUDIO clock — summed
///    frame durations — not `Date()`. A wall clock drifts against the samples and
///    is outright wrong for anything replayed out of the spool minutes later.
///
/// Changing `Endpointer` to serve both would have retuned the live voice turn,
/// which is the one thing this task must leave byte-for-byte alone.
///
/// Pure: no AVFoundation, no timers, no I/O.
final class AmbientSegmenter {

    // MARK: - Tuning

    /// Opens an utterance. Well below `Endpointer.speechThreshold` (0.012) because
    /// there is no AGC in the ambient path and the talker may be metres away.
    /// Above the noise floor of a quiet room, which measures under 0.001.
    static let speechThreshold = 0.0045

    /// Closes one. Hysteresis, same idea as `Endpointer`: a separate lower gate
    /// stops a voice sitting on the boundary from chattering open and shut.
    static let silenceThreshold = 0.0022

    /// End-of-utterance wait. Longer than the voice turn's 650 ms: nobody is
    /// waiting on a reply here, so cutting a sentence in half to feel responsive
    /// buys nothing and costs the transcript a clean boundary.
    static let silenceMs = 800

    /// Below this much voiced audio an utterance is a door, a cup, a cough. In a
    /// room this fires far more often than it does on a phone held to a face, so
    /// the floor is higher than `Endpointer.minUtteranceMs` (250).
    static let minUtteranceMs = 400

    /// Hard cap. Not a safety valve as in the voice turn but a CHUNKING rule: a
    /// twenty-minute monologue has to reach the transcript as readable rows while
    /// it is still being spoken, so a long run of speech is cut here and the next
    /// row continues it.
    static let maxUtteranceMs = 15000

    /// Speech rarely starts exactly on a frame boundary, and the opening consonant
    /// sits in the frame BEFORE the one that crossed the gate. The reported start
    /// is backdated by this much so a transcript row is not missing its first
    /// sound. Only the timestamp moves — no audio is re-sent.
    static let leadInMs = 120

    // MARK: - State

    /// Ms of audio seen since capture began. The only clock this class has.
    private(set) var elapsedMs = 0
    private(set) var speaking = false
    /// Where the open utterance started, already backdated by `leadInMs`.
    private(set) var startMs = 0
    /// Contiguous silence at the tail, 0 while voiced.
    private(set) var silenceRunMs = 0
    /// Voiced ms in this utterance — silence does not count towards `minUtteranceMs`.
    private(set) var voicedMs = 0
    /// Where the last voiced frame ended, which is where the utterance really
    /// ended — not `elapsedMs`, which by then includes the whole silent wait.
    private var lastVoicedEndMs = 0

    /// Feed one frame. `amp` is normalized PEAK amplitude 0...1 (use
    /// `voicePeakAmplitude`, the same measure `Endpointer` takes, so the two sets
    /// of thresholds are comparable), `dtMs` its duration from the byte count.
    @discardableResult
    func update(_ amp: Double, _ dtMs: Int) -> AmbientSegmentEvent {
        guard dtMs > 0 else { return .none }
        elapsedMs += dtMs

        if !speaking {
            guard amp > Self.speechThreshold else { return .none }
            speaking = true
            startMs = max(elapsedMs - dtMs - Self.leadInMs, 0)
            voicedMs = dtMs
            silenceRunMs = 0
            lastVoicedEndMs = elapsedMs
            return .started(atMs: startMs)
        }

        if amp < Self.silenceThreshold {
            silenceRunMs += dtMs
            if voicedMs < Self.minUtteranceMs {
                // Not speech. Discard once the full wait has passed, so the
                // detector is ready for the real utterance rather than wedged.
                if silenceRunMs >= Self.silenceMs { reset() }
                return .none
            }
            if silenceRunMs >= Self.silenceMs { return close() }
        } else {
            voicedMs += dtMs
            silenceRunMs = 0
            lastVoicedEndMs = elapsedMs
        }

        // Checked after the silence rule so a naturally-ending utterance reports
        // its real end rather than the cap.
        if elapsedMs - startMs >= Self.maxUtteranceMs, voicedMs >= Self.minUtteranceMs {
            return close()
        }
        return .none
    }

    /// End the open utterance now — capture is stopping, or the mic was
    /// interrupted. Returns nil when there was nothing worth reporting, so a
    /// caller can always ask.
    func flush() -> AmbientSegmentEvent? {
        guard speaking, voicedMs >= Self.minUtteranceMs else {
            reset()
            return nil
        }
        return close()
    }

    /// Back to pre-speech WITHOUT rewinding `elapsedMs`: the audio clock is the
    /// session's, not the utterance's, and restarting it would make every later
    /// timestamp collide with an earlier one.
    func reset() {
        speaking = false
        startMs = 0
        voicedMs = 0
        silenceRunMs = 0
        lastVoicedEndMs = elapsedMs
    }

    /// Wind the audio clock forward over a stretch we did not hear — a pause, an
    /// interruption — so timestamps after it still line up with wall time.
    func skip(ms: Int) {
        guard ms > 0 else { return }
        elapsedMs += ms
        lastVoicedEndMs = elapsedMs
    }

    private func close() -> AmbientSegmentEvent {
        let event = AmbientSegmentEvent.ended(startMs: startMs, endMs: max(lastVoicedEndMs, startMs))
        reset()
        return event
    }
}
