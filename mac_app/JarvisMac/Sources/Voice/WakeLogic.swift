import Foundation

// The "Hey Jarvis" wake word's pure rules: nothing from Speech, AVFoundation or
// AppKit in here, so all of it runs in the tests (Tests/VoiceTests.swift).
// After coucou's WakePhrase / EnergyVAD / WakeWindowBackoff / SpotterGeneration /
// VoiceWakeFilter (github.com/Louis-CFM/coucou, MIT).

/// "Hey Jarvis" and "OK Jarvis", found anywhere in what the recognizer heard, as
/// whole words. "Jarvis" alone never wakes it (it comes up in conversation).
enum WakePhrase {
    /// What the recognizer writes for "Jarvis" now and then.
    private static let jarvis: Set<String> = ["jarvis", "jervis", "jarvus", "jarvas", "jarves", "javis", "jarviss"]
    private static let callers: Set<String> = ["hey", "hay", "ok", "okay"]

    static func matches(_ heard: String) -> Bool {
        let words = normalise(heard).split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }
        for i in 0..<(words.count - 1) where callers.contains(words[i]) {
            if jarvis.contains(words[i + 1]) { return true }
            // Split by the recognizer: "jar vis".
            if i + 2 < words.count, words[i + 1] == "jar", words[i + 2] == "vis" { return true }
        }
        return false
    }

    /// Lowercase, punctuation gone, single spaces: "  Hey, JARVIS! " → "hey jarvis".
    /// "O.K." becomes "ok".
    static func normalise(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                return scalar == "." || scalar == "'" || scalar == "’" ? "\u{0}" : " "
            }
            return Character(scalar)
        }
        return String(kept).replacingOccurrences(of: "\u{0}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// An energy voice-activity detector: the spotter only runs the recognizer
/// while something louder than the room is heard.
///
/// - Calibration (~0.5 s): learns the noise floor fast, never triggers.
/// - Then the floor drifts slowly; a segment starts at 8× the floor and ends after
///   ~0.8 s under 2× it, or after 30 s whatever happens (endless noise becomes the
///   new floor).
/// - `reset()` keeps the learned floor.
struct EnergyVAD {
    enum Event: Equatable { case none, start, end }

    static let referenceRate = 43.0     // 1024-frame buffers at 44.1 kHz
    static let calibFrames = 22         // ≈ 0.5 s
    static let riseRatio = 8.0
    static let fallRatio = 2.0
    static let silenceFrames = 35       // ≈ 0.8 s
    static let maxActiveFrames = 1300   // ≈ 30 s

    private var calibLimit = EnergyVAD.calibFrames
    private var silenceLimit = EnergyVAD.silenceFrames
    private var activeLimit = EnergyVAD.maxActiveFrames
    private var kCalib = 0.15, kIdle = 0.005, kSilent = 0.001
    private(set) var frameRate = EnergyVAD.referenceRate

    private(set) var isActive = false
    private(set) var noisePower = 1e-7
    private var calibCount = 0
    private var silentCount = 0
    private var activeCount = 0
    private var segmentPowerSum = 0.0
    private var segmentPowerCount = 0

    /// Buffers per second actually delivered (macOS often hands 100 ms buffers):
    /// the same durations and the same smoothing per second at any rate.
    mutating func setFrameRate(_ fps: Double) {
        guard fps > 1 else { return }
        frameRate = fps
        let r = fps / Self.referenceRate
        calibLimit = max(1, Int((Double(Self.calibFrames) * r).rounded()))
        silenceLimit = max(1, Int((Double(Self.silenceFrames) * r).rounded()))
        activeLimit = max(1, Int((Double(Self.maxActiveFrames) * r).rounded()))
        func k(_ perRefFrame: Double) -> Double { 1 - pow(1 - perRefFrame, 1 / r) }
        kCalib = k(0.15); kIdle = k(0.005); kSilent = k(0.001)
    }

    mutating func reset() {
        isActive = false
        silentCount = 0
        activeCount = 0
        segmentPowerSum = 0
        segmentPowerCount = 0
    }

    /// One buffer's mean-square power.
    mutating func feed(_ power: Double) -> Event {
        if calibCount < calibLimit {
            calibCount += 1
            noisePower = noisePower * (1 - kCalib) + power * kCalib
            return .none
        }
        if !isActive {
            noisePower = noisePower * (1 - kIdle) + power * kIdle
            guard power > noisePower * Self.riseRatio else { return .none }
            isActive = true
            silentCount = 0
            activeCount = 0
            segmentPowerSum = power
            segmentPowerCount = 1
            return .start
        }
        activeCount += 1
        segmentPowerSum += power
        segmentPowerCount += 1
        if activeCount >= activeLimit {
            if segmentPowerCount > 0 { noisePower = segmentPowerSum / Double(segmentPowerCount) }
            reset()
            return .end
        }
        if power < noisePower * Self.fallRatio {
            silentCount += 1
            noisePower = noisePower * (1 - kSilent) + power * kSilent
            if silentCount >= silenceLimit {
                reset()
                return .end
            }
        } else {
            silentCount = 0
        }
        return .none
    }
}

/// When a wake window ends without the phrase: reopen at once after a normal
/// window, back off 0.5 → 1 → … s after quick failures, and after three in a row
/// wait for the next burst of voice.
struct WakeBackoff {
    enum Action: Equatable {
        case open
        case delay(TimeInterval)
        case stop
    }

    let fastThreshold: TimeInterval
    let maxFastFails: Int
    let base: TimeInterval
    let maxDelay: TimeInterval
    private(set) var streak = 0

    init(fastThreshold: TimeInterval = 1.0, maxFastFails: Int = 3, base: TimeInterval = 0.5, maxDelay: TimeInterval = 5.0) {
        self.fastThreshold = fastThreshold
        self.maxFastFails = maxFastFails
        self.base = base
        self.maxDelay = maxDelay
    }

    mutating func windowEnded(elapsed: TimeInterval, wasError: Bool) -> Action {
        guard elapsed < fastThreshold else {
            streak = 0
            return .open
        }
        streak += 1
        guard streak < maxFastFails else { return .stop }
        return .delay(min(base * pow(2, Double(streak - 1)), maxDelay))
    }

    mutating func reset() { streak = 0 }
}

/// The watchdog may rebuild the audio pipeline (a stalled tap, a deaf
/// recognizer, a headset plugged in), but never in a loop: at least 5 s apart
/// and at most 5 a minute. Past that the spotter says so in Settings.
struct RebuildLimiter {
    static let minInterval: TimeInterval = 5
    static let perMinute = 5

    private var last: TimeInterval?
    private var windowStart: TimeInterval = -.infinity
    private var count = 0

    mutating func allow(at now: TimeInterval) -> Bool {
        if now - windowStart >= 60 {
            windowStart = now
            count = 0
        }
        if let last, now - last < Self.minInterval { return false }
        guard count < Self.perMinute else { return false }
        count += 1
        last = now
        return true
    }
}

/// Each recognition task carries the generation it was opened in; callbacks
/// from a task that was closed meanwhile are dropped.
struct SpotterGeneration {
    private(set) var current = 0

    @discardableResult
    mutating func bump() -> Int {
        current += 1
        return current
    }

    func isValid(_ gen: Int) -> Bool { gen == current }
}

/// What the wake word is doing, for Settings.
enum WakeStatus: Equatable {
    enum Permission: Equatable { case microphone, speech }

    case off
    case needsPermission(Permission)
    /// No on-device recognizer for the Mac's language.
    case unavailable
    case paused(String)
    case listening
}

/// Everything that decides whether the spotter holds the microphone.
struct WakeConditions: Equatable {
    var enabled = false
    var micAllowed = true
    var speechAllowed = true
    var recognizerAvailable = true
    var locked = false
    var asleep = false
    var lowPower = false
    /// Flow dictation has the microphone.
    var dictating = false
    /// The note-taker is recording a call.
    var recordingNote = false
    /// The Jarvis voice panel is open (it has the microphone).
    var voiceOpen = false

    var status: WakeStatus {
        guard enabled else { return .off }
        if !micAllowed { return .needsPermission(.microphone) }
        if !speechAllowed { return .needsPermission(.speech) }
        if !recognizerAvailable { return .unavailable }
        if voiceOpen { return .paused("Jarvis is listening") }
        if locked { return .paused("the screen is locked") }
        if asleep { return .paused("the screen is asleep") }
        if lowPower { return .paused("Low Power Mode is on") }
        if dictating { return .paused("you're dictating") }
        if recordingNote { return .paused("a call is being recorded") }
        return .listening
    }

    var shouldRun: Bool { status == .listening }
}

/// A wake heard while the island waits on you (an approval, a question) or
/// while you type in it (the chat) is ignored: those need your hands first.
enum WakeFilter {
    static func blocked(pending: Bool, typing: Bool) -> String? {
        if pending { return "an approval or a question is waiting" }
        if typing { return "you're typing in the island" }
        return nil
    }
}
