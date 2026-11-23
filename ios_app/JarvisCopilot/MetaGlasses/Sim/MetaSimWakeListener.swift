import AVFoundation
import CallKit
import Speech

/// Whether a real phone or FaceTime call is ringing or on (CallKit tells any app that much, never
/// who). The simulator's hands-free listener stays off the mic while one is: FaceTime owns it, and
/// starting an audio tap then crashed the app (2026-11-22, installTap on a 0 Hz input).
@MainActor
final class MetaRealCallWatch: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = MetaRealCallWatch()
    @Published private(set) var busy = false
    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        refresh()
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in self.refresh() }
    }

    private func refresh() {
        busy = observer.calls.contains { !$0.hasEnded }
    }
}

/// Hands-free "Hey Jarvis" for the simulated glasses: while the Sim screen is open and the switch
/// is on, the phone mic stands in for the glasses' always-on wake detector. On-device speech
/// recognition watches for the enrolled phrase; when it hears it, everything said after the phrase
/// (until ~1 s of quiet, 8 s at most) is handed over as glasses-mic audio, and the listener lets go
/// of the mic before the voice turn starts. Never runs in the background.
@MainActor
final class MetaSimWakeListener: ObservableObject {
    enum State: Equatable { case off, listening, heard, failed(String) }
    @Published private(set) var state: State = .off

    /// The words after the wake phrase, 16 kHz mono PCM16.
    var onWake: ((Data) -> Void)?
    /// The moment the phrase is heard (before the question is captured).
    var onHeard: (() -> Void)?
    /// His chosen "listening" chime (the Jarvis voice earcon), so he knows the wake word fired —
    /// the real glasses chime on wake too.
    var earcon: EarconPlaying = ToneEarconPlayer()

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var holdsSession = false
    private let capture = Capture()
    private var phrase = "hey jarvis"

    var isListening: Bool { state == .listening || state == .heard }

    func start(phrase: String) async {
        guard !isListening else { return }
        self.phrase = phrase.lowercased()
        guard await Self.authorize() else { state = .failed("Allow speech recognition and the microphone for Jarvis in Settings"); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            state = .failed("On-device speech recognition isn't available")
            return
        }
        self.recognizer = recognizer
        do {
            try AudioSessionArbiter.shared.hold(.recording)
            holdsSession = true
            MetaGlassesHaptics.allowWhileRecording(true)
            try startEngine()
            beginRecognition()
            state = .listening
        } catch {
            stop()
            state = .failed("Couldn't start listening: \(error.localizedDescription)")
        }
    }

    func stop() {
        restartTask?.cancel(); restartTask = nil
        task?.cancel(); task = nil
        capture.setRequest(nil)
        request?.endAudio(); request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        capture.reset()
        if holdsSession {
            holdsSession = false
            MetaGlassesHaptics.allowWhileRecording(false)
            try? AudioSessionArbiter.shared.release(.recording)
        }
        if case .failed = state {} else { state = .off }
    }

    private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// A tap on an input with no rate or channels throws an Objective-C exception (the app dies):
    /// that's what the mic looks like while a call or another app holds it.
    nonisolated static func micFormatUsable(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate > 0 && channels > 0
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard Self.micFormatUsable(sampleRate: format.sampleRate, channels: format.channelCount) else {
            throw NSError(domain: "MetaSimWakeListener", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the mic is busy (a call or another app). Hey Jarvis comes back after"])
        }
        capture.configure(from: format)
        input.removeTap(onBus: 0)
        let capture = self.capture
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            // On the audio thread: the buffer is reused once this returns, so use it now.
            capture.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// A recognition task lasts about a minute; restart it while idle so listening never lapses.
    private func beginRecognition() {
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        self.request = request
        capture.reset()
        capture.setRequest(request)
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.handle(result: result, error: error) }
        }
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard let self, !Task.isCancelled, self.state == .listening else { return }
            self.request?.endAudio()
            self.beginRecognition()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard state == .listening else { return }
        if let result {
            let segments = result.bestTranscription.segments.map { (text: $0.substring, end: $0.timestamp + $0.duration) }
            if let wakeEnd = Self.wakeEnd(in: segments, phrase: phrase) {
                heard(after: wakeEnd)
                return
            }
        }
        if error != nil || result?.isFinal == true {
            beginRecognition()      // a recognition task ended on its own; keep listening
        }
    }

    /// The wake word fired: the chime, a tap, and whoever's watching (the 3D model glides to the mics).
    func announceWake() {
        earcon.play(.listening)
        MetaGlassesHaptics.micOpened()
        onHeard?()
    }

    /// Heard the phrase: keep capturing until the speaker pauses, then hand over what followed it.
    private func heard(after wakeEnd: TimeInterval) {
        state = .heard
        restartTask?.cancel()
        announceWake()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let began = clock.now
            let wakeTime = Date().addingTimeInterval(0.3)
            // Like the glasses: wait up to 4 s for the question to start, then for 1 s of quiet.
            while clock.now - began < .seconds(8) {
                try? await Task.sleep(for: .milliseconds(100))
                let spoke = self.capture.spoke(since: wakeTime)
                if spoke, self.capture.quietFor(seconds: 1.0) { break }
                if !spoke, clock.now - began > .seconds(4) { break }
            }
            let pcm = self.capture.pcm(after: wakeEnd)
            // His "done" chime while the mic is still held, then let go: releasing the session
            // first cut the chime off before it was heard (2026-11-22).
            let holdMs = self.earcon.play(.thinking)
            try? await Task.sleep(for: .milliseconds(holdMs))
            self.stop()
            self.onWake?(pcm)
        }
    }

    /// Whether the hands-free listener may hold the mic now. Off whenever anything else needs the mic
    /// or the turn isn't over: it used to restart in the gaps (the hold-to-talk chime handoff, Jarvis
    /// thinking after a ring press, the app going to the background) and grab the mic from the
    /// glasses path — "mic blocked" (2026-11-22).
    /// `onCall`: an answered phone call owns the glasses' mic (a ringing one doesn't — "Hey Jarvis,
    /// answer" is how you pick it up hands-free).
    nonisolated static func shouldListen(onScreen: Bool, appActive: Bool, switchOn: Bool, enrolled: Bool,
                                         turnRunning: Bool, pressing: Bool, handingOff: Bool,
                                         capturingQuestion: Bool, assistantBusy: Bool, jarvisSpeaking: Bool,
                                         onCall: Bool = false) -> Bool {
        onScreen && appActive && switchOn && enrolled
            && !turnRunning && !pressing && !handingOff && !capturingQuestion && !assistantBusy && !jarvisSpeaking
            && !onCall
    }

    /// Where the wake phrase ends in the transcription (seconds), or nil. Forgiving about how the
    /// recognizer spells it: "Hey Jarvis", "hey, jarvis", "a jarvis", "hey jervis".
    nonisolated static func wakeEnd(in segments: [(text: String, end: TimeInterval)], phrase: String = "hey jarvis") -> TimeInterval? {
        let words = phrase.lowercased().split(separator: " ").map(String.init)
        guard let name = words.last else { return nil }
        let greetings: Set<String> = Set(words.dropLast()).union(["hey", "hi", "a", "hay", "okay", "ok", "hej"])
        let clean = segments.map { (word: $0.text.lowercased().filter(\.isLetter), end: $0.end) }
        for (i, seg) in clean.enumerated() where distance(seg.word, name) <= (name.count > 4 ? 2 : 1) && seg.word.count >= 4 {
            if i > 0, greetings.contains(clean[i - 1].word) { return seg.end }
            if words.count == 1 { return seg.end }
        }
        return nil
    }

    nonisolated static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0 ... b.count)
        for i in 1 ... a.count {
            var previous = row[0]
            row[0] = i
            for j in 1 ... b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// The mic audio since the recognition task began, as 16 kHz mono PCM16, plus a loudness trail.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var converter: AVAudioConverter?
        private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        private var data = Data()
        private var lastLoud = Date()
        private var request: SFSpeechAudioBufferRecognitionRequest?

        func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
            lock.lock(); defer { lock.unlock() }
            self.request = request
        }

        func configure(from format: AVAudioFormat) {
            lock.lock(); defer { lock.unlock() }
            converter = AVAudioConverter(from: format, to: target)
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            data.removeAll()
            lastLoud = Date()
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.int16ChannelData, out.frameLength > 0 else { return }
            let samples = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
            data.append(samples)
            let peak = samples.reduce(0) { max($0, abs(Int($1))) }
            if peak > 1_500 { lastLoud = Date() }
            if data.count > 16_000 * 2 * 70 { data.removeFirst(data.count - 16_000 * 2 * 70) }
        }

        func spoke(since date: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return lastLoud > date
        }

        func quietFor(seconds: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastLoud) >= seconds
        }

        func pcm(after seconds: TimeInterval) -> Data {
            lock.lock(); defer { lock.unlock() }
            let offset = min(data.count, max(0, Int(seconds * 16_000) * 2))
            return data.subdata(in: offset ..< data.count)
        }
    }
}
