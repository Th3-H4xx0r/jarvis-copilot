import Foundation
import XCTest
@testable import JarvisCopilot

// Mocks for every platform boundary the voice stack sits on, so the whole turn
// machine runs in a unit test with no audio hardware, no recognizer and no socket.

// MARK: - Clock

/// Hand-cranked clock. `advance` fires everything due, in order, including
/// timers that the callbacks themselves schedule (the resume/watchdog loops
/// re-arm, so this matters).
@MainActor
final class TestVoiceClock: VoiceClock {

    private final class Token: VoiceTimerToken {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var current = Date(timeIntervalSince1970: 1_700_000_000)
    private var scheduled: [(fire: Date, token: Token, body: @MainActor () -> Void)] = []

    var now: Date { current }

    func schedule(after ms: Int, _ body: @escaping @MainActor () -> Void) -> VoiceTimerToken {
        let token = Token()
        scheduled.append((current.addingTimeInterval(Double(ms) / 1000), token, body))
        return token
    }

    func advance(ms: Int) {
        let target = current.addingTimeInterval(Double(ms) / 1000)
        var guardCount = 0
        while guardCount < 10_000 {
            guardCount += 1
            scheduled.removeAll { $0.token.cancelled }
            guard let next = scheduled.filter({ $0.fire <= target }).min(by: { $0.fire < $1.fire })
            else { break }
            scheduled.removeAll { $0.token === next.token }
            current = next.fire
            next.body()
        }
        current = target
        scheduled.removeAll { $0.token.cancelled }
    }

    var pendingTimers: Int { scheduled.filter { !$0.token.cancelled }.count }
}

// MARK: - Mic

@MainActor
final class MockAudioInput: AudioInput {
    var onFrame: ((Data) -> Void)?
    private(set) var isRunning = false

    var permission = true
    var startError: Error?
    /// Hold `start` open until `releaseStart()`. The real engine retries for up
    /// to ~1.75 s, so a stop/teardown can easily land in the middle of one.
    var stallStart = false
    private(set) var startedRates: [Int] = []
    private(set) var stopCount = 0

    private var startGate: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool { permission }

    func start(sampleRate: Int) async throws {
        if stallStart {
            await withCheckedContinuation { startGate = $0 }
        }
        if let startError { throw startError }
        startedRates.append(sampleRate)
        isRunning = true
    }

    /// Let a stalled `start` finish.
    func releaseStart() {
        let gate = startGate
        startGate = nil
        gate?.resume()
    }

    func stop() async {
        isRunning = false
        stopCount += 1
    }

    /// Push one mic frame of constant-amplitude audio.
    func emit(amplitude: Double, ms: Int, sampleRate: Int = VoiceStore.micRate) {
        onFrame?(Self.pcm(amplitude: amplitude, ms: ms, sampleRate: sampleRate))
    }

    /// Push `ms` of audio as 20 ms frames — how the real tap arrives, and what
    /// the endpointer's budget assumes.
    func emitFrames(amplitude: Double, ms: Int, frameMs: Int = 20) {
        var left = ms
        while left > 0 {
            let dt = min(frameMs, left)
            left -= dt
            emit(amplitude: amplitude, ms: dt)
        }
    }

    static func pcm(amplitude: Double, ms: Int, sampleRate: Int = VoiceStore.micRate) -> Data {
        let samples = max(sampleRate * ms / 1000, 1)
        let raw = UInt16(bitPattern: Int16(clamping: Int(amplitude * 32767)))
        var out = Data(capacity: samples * 2)
        for _ in 0..<samples {
            out.append(UInt8(raw & 0xFF))
            out.append(UInt8((raw >> 8) & 0xFF))
        }
        return out
    }
}

// MARK: - Playback

@MainActor
final class MockAudioOutput: AudioOutput {
    var isStreamAvailable = true
    /// Make `startStream` refuse, to exercise the WAV-clip fallback.
    var streamStartSucceeds = true
    /// Make `play` fail, to exercise "skip a bad clip".
    var playSucceeds = true
    /// Reported through `onClipDuration` when > 0 (as the real player does).
    var clipDuration: TimeInterval = 0

    private(set) var startedStreams: [Int] = []
    private(set) var fed = Data()
    private(set) var flushCount = 0
    private(set) var stopStreamCount = 0
    private(set) var played: [(bytes: Data, ext: String)] = []
    private(set) var stopClipCount = 0

    var onClipComplete: (() -> Void)?
    var onClipPosition: ((TimeInterval) -> Void)?
    var onClipDuration: ((TimeInterval) -> Void)?

    func startStream(sampleRate: Int) async -> Bool {
        guard streamStartSucceeds else { return false }
        startedStreams.append(sampleRate)
        return true
    }

    func feed(_ pcm: Data) async { fed.append(pcm) }
    func flushStream() async { flushCount += 1 }
    func stopStream() async { stopStreamCount += 1 }

    func play(_ bytes: Data, fileExtension: String) async -> Bool {
        guard playSucceeds else { return false }
        played.append((bytes, fileExtension))
        if clipDuration > 0 { onClipDuration?(clipDuration) }
        return true
    }

    func stopClip() async { stopClipCount += 1 }

    /// The current clip reached its end.
    func finishClip() { onClipComplete?() }
    func report(position: TimeInterval) { onClipPosition?(position) }

    /// PCM payloads of the WAV clips handed to `play`, concatenated — the
    /// ordering guarantee, minus the 44-byte headers.
    var playedPcm: Data {
        var out = Data()
        for clip in played where clip.ext == "wav" { out.append(clip.bytes.dropFirst(44)) }
        return out
    }
}

// MARK: - Recognizer

@MainActor
final class MockSpeechSession: SpeechSession {
    var onPartial: ((String) -> Void)?
    private(set) var isDone = false
    /// Resolved by `stop()`.
    var finalTranscript = ""
    /// Never resolve `stop()` on its own — SFSpeech's final callback is not
    /// guaranteed, which is the whole reason the caller needs a timeout.
    var stallStop = false
    private(set) var fedBytes = 0
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

    private var stopGate: CheckedContinuation<Void, Never>?

    func feed(_ pcm: Data) { fedBytes += pcm.count }

    func stop() async -> String {
        stopCount += 1
        if stallStop {
            await withCheckedContinuation { stopGate = $0 }
        }
        isDone = true
        return finalTranscript
    }

    func cancel() {
        cancelCount += 1
        isDone = true
        // Mirrors `DefaultSpeechSession.finish`, which resumes the pending
        // `stop()` continuation — that is what stops it leaking.
        finalTranscript = ""
        releaseStop()
    }

    /// Let a stalled `stop()` finish.
    func releaseStop() {
        let gate = stopGate
        stopGate = nil
        gate?.resume()
    }

    /// Pretend Apple ended the session on its own (it does, after a pause).
    func endItself() { isDone = true }
    func emitPartial(_ text: String) { onPartial?(text) }
}

@MainActor
final class MockSpeechRecognizing: SpeechRecognizing {
    var isAvailable = true
    /// nil = no on-device recognition here; the store falls back to server STT.
    var nextTranscript: String?
    private(set) var sessions: [MockSpeechSession] = []
    private(set) var startCount = 0
    private(set) var promptFlags: [Bool] = []

    func startSession(sampleRate: Int, prompt: Bool) async -> SpeechSession? {
        startCount += 1
        promptFlags.append(prompt)
        guard isAvailable else { return nil }
        let session = MockSpeechSession()
        session.finalTranscript = nextTranscript ?? ""
        sessions.append(session)
        return session
    }

    var latest: MockSpeechSession? { sessions.last }
}

// MARK: - Local synthesizer

@MainActor
final class MockVoiceSynthesizing: VoiceSynthesizing {
    var isAvailable = true
    var speakSucceeds = true
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    @discardableResult
    func speak(_ text: String, rate: Float) async -> Bool {
        guard speakSucceeds else { return false }
        spoken.append(text)
        return true
    }

    func stop() { stopCount += 1 }
}

// MARK: - Audio session

@MainActor
final class MockAudioSessionControlling: AudioSessionControlling {
    var onInterruption: ((AudioInterruption) -> Void)?
    var configureError: Error?
    /// Thrown by `setActive(true)` only — releasing the session is allowed to
    /// fail harmlessly, re-grabbing it is not.
    var activateError: Error?
    private(set) var configureCount = 0
    private(set) var activeCalls: [Bool] = []

    func configureForConversation() throws {
        if let configureError { throw configureError }
        configureCount += 1
    }

    func setActive(_ active: Bool) throws {
        activeCalls.append(active)
        if active, let activateError { throw activateError }
    }

    func simulate(_ event: AudioInterruption) { onInterruption?(event) }
}

// MARK: - Realtime socket

@MainActor
final class MockVoiceSocket: VoiceSocket {
    var onFrame: ((VoiceSocketFrame) -> Void)?
    var onClose: ((Error?) -> Void)?

    private(set) var sentText: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var closeCount = 0

    func send(text: String) { sentText.append(text) }
    func send(data: Data) { sentData.append(data) }
    func close() { closeCount += 1 }

    // Drive the client from the "server" side.
    func receive(text: String) { onFrame?(.text(text)) }
    func receive(json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        receive(text: String(data: data, encoding: .utf8)!)
    }
    func receive(binary: Data) { onFrame?(.binary(binary)) }
    func serverClosed(_ error: Error? = nil) { onClose?(error) }

    var sentJSON: [[String: Any]] {
        sentText.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
    var sentTypes: [String] { sentJSON.compactMap { $0["type"] as? String } }
    func lastMessage(ofType type: String) -> [String: Any]? {
        sentJSON.last { ($0["type"] as? String) == type }
    }
}

@MainActor
final class MockVoiceSocketConnector: VoiceSocketConnecting {
    var connectError: Error?
    private(set) var connectedURLs: [URL] = []
    private(set) var connectedHeaders: [[String: String]] = []
    private(set) var socket: MockVoiceSocket?

    func connect(url: URL, headers: [String: String]) async throws -> VoiceSocket {
        if let connectError { throw connectError }
        connectedURLs.append(url)
        connectedHeaders.append(headers)
        let fresh = MockVoiceSocket()
        socket = fresh
        return fresh
    }
}

// MARK: - Helpers

/// Let the `Task`s an @MainActor store spawns for its effects run to completion.
///
/// Yielding alone is NOT enough: `MockTransport.send` and the per-sentence TTS
/// task group are nonisolated, so they hop off the main actor and a burst of
/// `Task.yield()` can spin through in microseconds while that work is still on
/// another thread. Each round therefore also gives the runtime real time.
func settleVoiceTasks(_ rounds: Int = 40) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Settle until `condition` holds, so a test never depends on a fixed number of
/// turns through the store's effect `Task`s. Returns whether it came true.
@discardableResult
@MainActor
func waitUntilVoice(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
    var waited = 0
    while waited < timeoutMs {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
        waited += 1
    }
    return condition()
}

/// `ms` of 24 kHz mono PCM16 reply audio with recognisable bytes.
func replyPcm(ms: Int, seed: Int = 0, sampleRate: Int = 24000) -> Data {
    let samples = sampleRate * ms / 1000
    var out = Data(count: samples * 2)
    for i in 0..<out.count { out[i] = UInt8((seed + i) & 0xFF) }
    return out
}
