import Foundation

/// Adaptive end-of-speech detection for the realtime voice turn (plan 1.1).
/// Direct port of `voice/endpointer.dart`.
///
/// Pure — no AVFoundation, no timers, no I/O — so the whole policy is unit
/// testable: the caller feeds it (amplitude, frame duration) pairs and acts on
/// the returned event.
///
/// The rules mirror the browser endpointer (webui/static/voice.js) exactly so a
/// turn feels identical on phone and web:
///
///   • energy VAD with HYSTERESIS — a high threshold opens the turn, a lower one
///     closes it, so a voice hovering near the boundary can't chatter
///   • base silence ends a normal utterance
///   • extended when the speaker is probably mid-thought: the tail was RISING in
///     energy, or the utterance so far is very short
///   • an utterance under `minUtteranceMs` of voiced audio is a blip (cough,
///     door, mic pop) — discarded, never endpointed
///   • 30 s hard cap so a stuck-open mic can't stream forever
enum EndpointEvent: Equatable, Sendable {
    /// Keep listening.
    case none
    /// The user has stopped talking — end the turn now.
    case endOfTurn
}

final class Endpointer {

    // MARK: - Tuning constants (plan 1.1)
    // All normalized peak amplitudes 0..1, all durations in milliseconds. These
    // are the ONLY timing numbers in the endpointing path — nothing downstream
    // may hard-code a silence wait.

    /// Opens a turn. Calibrated against PEAK (not RMS) amplitude, matching the
    /// webui VAD — RMS runs several times smaller and would never cross this.
    static let speechThreshold = 0.08

    /// Closes a turn. Deliberately LOWER than `speechThreshold`: the gap is the
    /// hysteresis band that stops a voice sitting near the boundary from
    /// flapping between "speaking" and "silent" every frame.
    static let silenceThreshold = 0.04

    /// Normal end-of-speech wait. 650 ms: 400 ms cut people off mid-sentence (an
    /// ordinary clause break is 300–600 ms), while the old 1500 ms put a full
    /// second of dead air into every turn.
    static let baseSilenceMs = 650

    /// Used instead of `baseSilenceMs` when the speaker looks mid-thought (see
    /// `requiredSilenceMs`). Long enough to ride out a breath, short enough that
    /// a genuinely finished turn still beats the old fixed wait by ~2×.
    static let extendedSilenceMs = 1100

    /// An utterance with less voiced audio than this gets the extended window —
    /// people who have only said one word ("Jarvis…") are usually still loading
    /// the rest of the sentence.
    static let shortUtteranceMs = 1200

    /// Less voiced audio than this is not speech at all. We discard it (reset to
    /// pre-speech) rather than ending a turn on a cough or a mic pop.
    static let minUtteranceMs = 250

    /// Hard cap on one utterance. Beyond this we endpoint regardless — a mic that
    /// never goes quiet (fan, TV, pocket) must not stream forever.
    static let maxUtteranceMs = 30000

    /// Window of voiced audio compared against the window before it to decide
    /// whether the tail is rising.
    static let tailWindowMs = 150

    /// The tail counts as rising when its mean energy exceeds the preceding
    /// window's by this factor. 1.15 ignores ordinary syllable-to-syllable wobble
    /// while still catching a genuine "…and —" lift.
    static let risingTailRatio = 1.15

    // MARK: - State

    private var _speaking = false
    /// Total ms since the turn opened (voiced + trailing silence).
    private var _speechMs = 0
    /// Ms of contiguous sub-threshold audio at the tail.
    private var _silenceMs = 0
    /// Latched when the current silence run began.
    private var _risingTail = false

    private struct Frame { let ms: Int; let amp: Double }
    /// Recent VOICED frames, newest last. Bounded to two tail windows — that's
    /// all `computeRisingTail` ever looks at.
    private var tail: [Frame] = []

    /// True while a turn is open (speech has started and hasn't been endpointed).
    var speaking: Bool { _speaking }

    /// Milliseconds since the turn opened, including the trailing silence.
    var speechMs: Int { _speechMs }

    /// Milliseconds of contiguous silence at the tail (0 while voiced).
    var silenceMs: Int { _silenceMs }

    /// Milliseconds of actual voiced audio in this turn.
    var voicedMs: Int { _speechMs - _silenceMs }

    /// How much trailing silence must accumulate before this turn ends. Extended
    /// when the speaker is probably mid-thought — a rising tail, or barely any
    /// speech yet.
    ///
    /// While silence is running we use the value latched at its onset; while
    /// still voiced we evaluate the tail live, so the getter always answers for
    /// the audio seen so far.
    var requiredSilenceMs: Int {
        let rising = _silenceMs > 0 ? _risingTail : computeRisingTail()
        return (rising || voicedMs < Self.shortUtteranceMs)
            ? Self.extendedSilenceMs
            : Self.baseSilenceMs
    }

    /// Feed one mic frame. `amp` is the frame's normalized PEAK amplitude (0..1)
    /// and `dtMs` its duration — use `frameMsForPcm16` rather than a wall clock
    /// so the decision is driven by the audio itself and can't drift with
    /// scheduler jitter.
    @discardableResult
    func update(_ amp: Double, _ dtMs: Int) -> EndpointEvent {
        if dtMs <= 0 { return .none }

        if !_speaking {
            if amp > Self.speechThreshold {
                _speaking = true
                _speechMs = dtMs
                _silenceMs = 0
                _risingTail = false
                tail = [Frame(ms: dtMs, amp: amp)]
            }
            return .none
        }

        _speechMs += dtMs

        if amp < Self.silenceThreshold {
            // Latch the rising-tail verdict at the moment silence starts: the
            // tail shape can't change once the speaker has stopped, and
            // re-deciding every frame would let the window flip mid-wait.
            if _silenceMs == 0 { _risingTail = computeRisingTail() }
            _silenceMs += dtMs

            if voicedMs < Self.minUtteranceMs {
                // Not speech — a blip. Discard the "turn" once we've waited out
                // the longest window, so the detector is ready for the real
                // utterance and can't sit wedged in `speaking` forever.
                if _silenceMs >= Self.extendedSilenceMs { reset() }
                return .none
            }
            if _silenceMs >= requiredSilenceMs { return .endOfTurn }
        } else {
            // Anything at or above the LOW threshold counts as still talking —
            // this is the hysteresis band. Restart the silence budget.
            _silenceMs = 0
            _risingTail = false
            pushTail(dtMs, amp)
        }

        // Checked last so a max-length turn still ends even while the mic is loud.
        if _speechMs >= Self.maxUtteranceMs { return .endOfTurn }
        return .none
    }

    /// Return to the pre-speech state (new turn, barge-in, teardown).
    func reset() {
        _speaking = false
        _speechMs = 0
        _silenceMs = 0
        _risingTail = false
        tail.removeAll()
    }

    private func pushTail(_ dtMs: Int, _ amp: Double) {
        tail.append(Frame(ms: dtMs, amp: amp))
        var total = tail.reduce(0) { $0 + $1.ms }
        // Keep two windows' worth; drop from the front once we have more.
        while tail.count > 1, total - tail[0].ms >= Self.tailWindowMs * 2 {
            total -= tail[0].ms
            tail.removeFirst()
        }
    }

    /// True when the last `tailWindowMs` of voiced audio is meaningfully louder
    /// than the window before it — the speaker was getting louder as they paused,
    /// which usually means they're not done.
    private func computeRisingTail() -> Bool {
        if tail.count < 2 { return false }
        var recentMs = 0, priorMs = 0
        var recentSum = 0.0, priorSum = 0.0
        for f in tail.reversed() {
            if recentMs < Self.tailWindowMs {
                recentMs += f.ms
                recentSum += f.amp * Double(f.ms)
            } else if priorMs < Self.tailWindowMs {
                priorMs += f.ms
                priorSum += f.amp * Double(f.ms)
            } else {
                break
            }
        }
        if recentMs == 0 || priorMs == 0 { return false }
        return (recentSum / Double(recentMs)) > (priorSum / Double(priorMs)) * Self.risingTailRatio
    }

    /// Duration of a mono PCM16 buffer of `byteLength` bytes at `sampleRate`.
    /// Frame timing comes from the audio itself, never from `Date()`.
    static func frameMsForPcm16(byteLength: Int, sampleRate: Int) -> Int {
        if byteLength <= 0 || sampleRate <= 0 { return 0 }
        return (byteLength / 2) * 1000 / sampleRate
    }
}

/// PEAK amplitude of a mono PCM16-LE chunk, normalized 0..1.
///
/// Peak and not RMS: the VAD thresholds above are calibrated against peak to
/// match the webui. RMS runs several times smaller, so with RMS the speech
/// threshold was never crossed and the turn never ended.
func voicePeakAmplitude(_ pcm: Data) -> Double {
    guard pcm.count >= 2 else { return 0 }
    let frames = pcm.count / 2
    var samples = [Int16](repeating: 0, count: frames)
    _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0, count: frames * 2) }
    var peak = 0.0
    for s in samples {
        let v = abs(Double(Int16(littleEndian: s)) / 32768.0)
        if v > peak { peak = v }
    }
    return min(max(peak, 0), 1)
}
