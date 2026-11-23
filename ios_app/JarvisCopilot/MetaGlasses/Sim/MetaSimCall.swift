import Foundation

/// A phone call as the simulated Ray-Ban Meta (Gen 2) sees it. The real glasses handle calls in their
/// own firmware (a Bluetooth hands-free headset that announces the caller); the simulator copies that.
/// What Jarvis may learn is only `status` — iOS gives apps no caller identity (CXCallObserver says
/// ringing / connected, nothing more), and the glasses give Jarvis no call control.
enum MetaPhoneCall: Equatable, Sendable {
    case none
    /// The caller is ringing; `seconds` of ringing so far (missed at `MetaGen2Profile.callRingSeconds`).
    case ringing(from: String, seconds: Double)
    /// On the call for `seconds`.
    case active(from: String, seconds: Double)

    /// What `meta_glasses_status` reports: never the caller.
    var status: String {
        switch self {
        case .none: return "none"
        case .ringing: return "ringing"
        case .active: return "active"
        }
    }

    /// Who's calling — for the wearer (the glasses say it out loud) and the sim page, not for Jarvis.
    var caller: String? {
        switch self {
        case .none: return nil
        case .ringing(let from, _), .active(let from, _): return from
        }
    }

    var seconds: Double {
        switch self {
        case .none: return 0
        case .ringing(_, let s), .active(_, let s): return s
        }
    }

    var isRinging: Bool { if case .ringing = self { return true }; return false }
    var isActive: Bool { if case .active = self { return true }; return false }
    var isOn: Bool { self != .none }
}

/// What the wearer did to the call.
enum MetaCallAction: String, Equatable, Sendable {
    case answer, reject, hangUp
}

/// What a touchpad gesture does while a call rings or is on.
enum MetaCallTouch: Equatable, Sendable {
    /// The glasses' call handling takes the gesture (overrides its default and any Jarvis binding).
    case call(MetaCallAction)
    /// The glasses refuse it (the assistant while on a call).
    case refused(String)
    /// The glasses do nothing with it (media gestures — the phone holds its media for the call).
    case ignored
}

/// The real glasses' call rules (Meta help pages, 2026-11-23): double-tap answers, press and hold
/// declines, "Hey Meta, answer / reject"; double-tap hangs up (Meta's own pages disagree — we use
/// double-tap). During a call the mic and speakers carry the call, so the assistant is off.
enum MetaCallRules {
    static let ringingReason = "A call is ringing — answer or decline it first"
    static let onCallReason = "On a call — the assistant is off until you hang up"

    /// nil = the gesture does its usual thing (swipes still set the volume during a call).
    static func touch(_ gesture: MetaTouchGesture, during call: MetaPhoneCall) -> MetaCallTouch? {
        switch call {
        case .none:
            return nil
        case .ringing:
            switch gesture {
            case .doubleTap: return .call(.answer)
            case .hold: return .call(.reject)
            case .tap, .tripleTap: return .ignored
            case .swipeForward, .swipeBackward, .capture: return nil
            }
        case .active:
            switch gesture {
            case .doubleTap: return .call(.hangUp)
            case .hold: return .refused(onCallReason)
            case .tap, .tripleTap: return .ignored
            case .swipeForward, .swipeBackward, .capture: return nil
            }
        }
    }

    /// What the touchpad tile should say the gesture does right now (nil = its usual label).
    static func label(_ gesture: MetaTouchGesture, during call: MetaPhoneCall) -> String? {
        switch touch(gesture, during: call) {
        case .call(.answer)?: return "Answer"
        case .call(.reject)?: return "Decline"
        case .call(.hangUp)?: return "Hang up"
        case .refused?: return "On a call"
        case .ignored?: return "Nothing"
        case nil: return nil
        }
    }

    /// What the glasses' mics heard while a call rings, as a call command — nil when it isn't one
    /// (or says both, "yes no"). Whole words only: "yesterday" isn't "yes", "answered" isn't "answer".
    static func voiceCommand(_ transcript: String) -> MetaCallAction? {
        let words = transcript.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map(String.init)
        var answer = false
        var reject = false
        for (i, word) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let after = i + 2 < words.count ? words[i + 2] : nil
            var answers = ["answer", "yes", "yeah", "accept", "pickup"].contains(word)
            if word == "pick", next == "up" || (["it", "this", "that"].contains(next ?? "") && after == "up") {
                answers = true
            }
            if answers {
                let negated = (i > 0 && ["don't", "dont"].contains(words[i - 1]))
                    || (i > 1 && words[i - 2] == "do" && words[i - 1] == "not")
                if negated { reject = true } else { answer = true }
            }
            if ["reject", "decline", "no", "nope"].contains(word) { reject = true }
        }
        guard answer != reject else { return nil }
        return answer ? .answer : .reject
    }

    /// A call's length as the phone shows it: 0:07, 1:05, 1:02:03.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Turns what the glasses' mics heard while a call rings into words, on the phone (on-device
/// recognition — nothing leaves it). The simulator then matches them with `MetaCallRules.voiceCommand`.
@MainActor
enum MetaCallSpeech {
    /// "" when recognition isn't available or nothing was understood (the call keeps ringing).
    static func transcribe(_ pcm: Data) async -> String {
        guard !pcm.isEmpty,
              let session = await DefaultSpeechRecognizing().startSession(sampleRate: 16_000, prompt: true) else { return "" }
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + SimulatedGlassesTransport.frameBytes, pcm.endIndex)
            session.feed(pcm.subdata(in: offset ..< end))
            offset = end
        }
        return await voiceStopWithDeadline(session, after: 3_000, clock: SystemVoiceClock())
    }
}
