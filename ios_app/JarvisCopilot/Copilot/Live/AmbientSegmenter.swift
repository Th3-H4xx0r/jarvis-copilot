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

    /// The FLOOR under the opening gate — never the whole gate. Well below
    /// `Endpointer.speechThreshold` (0.012) because there is no AGC in the ambient
    /// path and the talker may be metres away. Above the noise floor of a quiet
    /// room, which measures under 0.001.
    static let speechThreshold = 0.0045

    /// The floor under the closing gate. Hysteresis, same idea as `Endpointer`: a
    /// separate lower gate stops a voice sitting on the boundary from chattering
    /// open and shut.
    static let silenceThreshold = 0.0022

    // MARK: Tuning — the room's own level

    /// Why the two constants above are floors and not the gates themselves.
    ///
    /// They were absolute, and a real room sits ABOVE them. `voicePeakAmplitude`
    /// is a PEAK over a frame, so one sample in a thousand above 0.0022 (that is
    /// −53 dBFS) keeps a frame classified "voiced" — which a fridge, a fan, a
    /// street or a second conversation manages continuously. `silenceRunMs` then
    /// never reached `silenceMs`, so `close()` was only ever reached by the
    /// `maxUtteranceMs` chunking rule, and EVERY utterance was stamped as exactly
    /// one 15 s window. Measured on session `ea492bed`: spans of 15.05 / 15.08 /
    /// 15.08 s, one of them for the two words "Can you hear me?". The server
    /// slices identification audio from that span, so speaker embeddings were
    /// ~15 s of room tone and could not separate anyone — two halves of one
    /// utterance scored 0.29 against each other.
    ///
    /// So the gates are now relative to the room. The constants above remain as
    /// floors (a silent room must not make the gates vanish) and the constants
    /// below as ceilings (a loud room must not push them up into speech).

    /// How fast the floor estimate follows the room DOWN, per frame. Fast: a
    /// quietening room should stop holding the gates high almost at once.
    static let floorFallRate = 0.25

    /// And UP. Slow, so one door slam between utterances does not deafen the
    /// detector for the next thing said.
    static let floorRiseRate = 0.02

    /// Speech must beat the room by this much to open an utterance.
    static let speechOverFloor = 3.0

    /// And fall back to within this much of it to close one. Below
    /// `speechOverFloor`, which is what keeps the hysteresis.
    static let silenceOverFloor = 1.6

    /// Ceilings. A room loud enough to push the gates past these is a room where
    /// the gates have stopped being about speech, and an utterance that never
    /// opens is worse than one that runs long.
    static let maxSpeechGate = 0.05
    static let maxSilenceGate = 0.028

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

    /// The room's own peak level, learned between utterances.
    ///
    /// Seeded at `silenceThreshold` so the very first utterance of a session
    /// behaves exactly as the absolute gates used to, and adapts from there.
    /// Updated ONLY while not in an utterance: the frames inside one are speech,
    /// and letting them teach the floor would raise it until the talker's own
    /// voice read as silence.
    private(set) var roomFloor = AmbientSegmenter.silenceThreshold

    /// The level speech has to beat to open an utterance, for a given room.
    static func openGate(forFloor floor: Double) -> Double {
        min(max(speechThreshold, floor * speechOverFloor), maxSpeechGate)
    }

    /// The level the tail has to fall below to start closing one.
    ///
    /// Below `openGate` at EVERY floor, which is the hysteresis the whole design
    /// rests on: `silenceOverFloor` < `speechOverFloor`, `silenceThreshold` <
    /// `speechThreshold`, and `maxSilenceGate` < `maxSpeechGate`, so no room
    /// level can make the two cross.
    static func closeGate(forFloor floor: Double) -> Double {
        min(max(silenceThreshold, floor * silenceOverFloor), maxSilenceGate)
    }

    /// The opening gate for the room as it currently measures.
    var openGate: Double { Self.openGate(forFloor: roomFloor) }

    /// The closing gate for the room as it currently measures.
    var closeGate: Double { Self.closeGate(forFloor: roomFloor) }

    /// Feed one frame. `amp` is normalized PEAK amplitude 0...1 (use
    /// `voicePeakAmplitude`, the same measure `Endpointer` takes, so the two sets
    /// of thresholds are comparable), `dtMs` its duration from the byte count.
    @discardableResult
    func update(_ amp: Double, _ dtMs: Int) -> AmbientSegmentEvent {
        guard dtMs > 0 else { return .none }
        elapsedMs += dtMs

        if !speaking {
            guard amp > openGate else {
                // Only the room teaches the room's level, so this is the one place
                // the floor moves — and it is reached only by frames that did NOT
                // open an utterance.
                adaptFloor(to: amp)
                return .none
            }
            speaking = true
            startMs = max(elapsedMs - dtMs - Self.leadInMs, 0)
            voicedMs = dtMs
            silenceRunMs = 0
            lastVoicedEndMs = elapsedMs
            return .started(atMs: startMs)
        }

        if amp < closeGate {
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

    /// Follow the room, fast down and slow up.
    private func adaptFloor(to amp: Double) {
        guard amp.isFinite, amp >= 0 else { return }
        let rate = amp < roomFloor ? Self.floorFallRate : Self.floorRiseRate
        roomFloor = max(roomFloor + (amp - roomFloor) * rate, 0)
    }

    private func close() -> AmbientSegmentEvent {
        let event = AmbientSegmentEvent.ended(startMs: startMs, endMs: max(lastVoicedEndMs, startMs))
        reset()
        return event
    }
}
