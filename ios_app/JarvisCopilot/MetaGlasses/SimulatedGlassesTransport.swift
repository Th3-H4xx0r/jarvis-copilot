import AVFoundation
import UIKit

/// Something that can say text out loud — the glasses' open-ear speakers.
@MainActor
protocol MetaSpeaker: AnyObject {
    func say(_ text: String, volume: Int)
}

/// The phone speaker standing in for the glasses' speakers. Its own audio session, so it never
/// fights `AudioSessionArbiter` (the only writer of the app's session).
@MainActor
final class MetaPhoneSpeaker: MetaSpeaker {
    private let synthesizer: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.usesApplicationAudioSession = false
        return s
    }()

    func say(_ text: String, volume: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.volume = Float(max(0, min(volume, 100))) / 100
        synthesizer.speak(utterance)
    }
}

/// One photo or clip in the simulated glasses' storage (or imported to the phone).
struct MetaStoredMedia: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case photo, video }
    let id: UUID
    let kind: Kind
    let date: Date
    let bytes: Int64
    var fileURL: URL?
    let thumbnail: Data?
    var seconds: Double?
    var mode: MetaVideoMode?
    var source: String
}

/// The simulated Ray-Ban Meta (Gen 2): software glasses behind the same `GlassesTransport` the
/// real ones use, so Jarvis's tools, the voice turn and the touch handling run the real code.
///
/// It emulates the hardware AND its limits (`MetaGen2Profile`, `MetaHardwareState`): every command
/// is checked the way the glasses would — LED covered, too hot, battery low, storage full, folded,
/// in the case, out of range — and refused with the glasses' reason (`MetaGlassesError.refused`);
/// a recording or stream stops on its own when a limit hits mid-way. Battery and heat run on a
/// 1 s tick (× sim speed). The camera is the iPhone's (ultra-wide when present) or drawn test
/// scenes; the speakers are the phone's. Every command lands in the command feed.
///
/// It does NOT reimplement the BLE L2CAP channel or the AirShield crypto — those stay in
/// `MetaGlassesTransport`'s hardware-gated skeleton.
@MainActor
final class SimulatedGlassesTransport: ObservableObject, GlassesTransport {
    @Published private(set) var linkState: GlassesLinkState = .disconnected
    /// The glasses' physical state. Change it through the sim controls below, not directly.
    @Published private(set) var hw = MetaHardwareState()
    /// Sim speed for battery and heat: 1×, 10× or 60×.
    @Published var speed: Double = 1
    @Published private(set) var storage: [MetaStoredMedia] = []
    @Published private(set) var imported: [MetaStoredMedia] = []
    @Published private(set) var latestLiveFrame: Data?
    /// The capture LED is lit (recording, streaming, or a photo's blink).
    @Published private(set) var ledLit = false
    /// Media import / live view moved the phone onto the glasses' Wi-Fi (server traffic → cellular).
    @Published private(set) var phoneOnGlassesWiFi = false
    @Published private(set) var importProgress: Double?
    /// The simulated music the touchpad controls (track number in a pretend playlist).
    @Published private(set) var track = 1
    /// The part being exercised right now, for the 3D model's glide-and-pulse (nil = idle turntable).
    @Published private(set) var focus: MetaGlassesFocus?
    /// The enrolled custom wake phrase (nil = not set up; the touch-and-hold / button wake still works).
    @Published private(set) var wakePhrase: String?
    /// Where the enrolled phrase is remembered (the glasses keep it across power cycles).
    var wakeDefaults: UserDefaults? {
        didSet { wakePhrase = wakeDefaults?.string(forKey: "meta.sim.wakePhrase") }
    }
    private var focusTask: Task<Void, Never>?
    private var listening = false
    private var speaking = false
    var cameraName: String { camera.sourceName }

    private(set) var inbound: AsyncStream<GlassesInboundEvent>
    private var continuation: AsyncStream<GlassesInboundEvent>.Continuation
    let feed: MetaCommandFeed
    let camera: MetaCameraSource
    var speaker: MetaSpeaker?
    /// The glasses' touchpad defaults send media keys to the phone (AVRCP).
    var mediaKeys: ((MetaMediaCommand) async -> Void)?
    /// How long a Wi-Fi import really takes is scaled by this (tests use 0).
    var transferTimeScale: Double = 1

    /// Every frame the session sent down, in order — the assertion surface for tests.
    private(set) var sentFrames: [GlassesFrame] = []
    /// Called with every frame the session sends down.
    var onSent: ((GlassesFrame) -> Void)?

    private let autoTick: Bool
    private var tickTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var ledBlinkTask: Task<Void, Never>?
    private let mediaDirectory: URL
    /// 40 ms of 16 kHz mono PCM16.
    static let frameBytes = 1_280

    var hardware: MetaHardwareState? { hw }

    init(camera: MetaCameraSource? = nil, feed: MetaCommandFeed? = nil, autoTick: Bool = true,
         mediaDirectory: URL? = nil) {
        (inbound, continuation) = AsyncStream<GlassesInboundEvent>.makeStream(bufferingPolicy: .unbounded)
        self.camera = camera ?? MetaTestSceneCamera(photoSize: CGSize(width: 302, height: 403))
        self.feed = feed ?? MetaCommandFeed()
        self.autoTick = autoTick
        self.mediaDirectory = mediaDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("meta-sim-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: self.mediaDirectory, withIntermediateDirectories: true)
    }

    // MARK: GlassesTransport

    func connect() async throws {
        if let reason = hw.unreachableReason {
            linkState = .failed(reason)
            throw MetaGlassesError.refused(reason)
        }
        linkState = .ready   // an already-trusted in-memory session
        if autoTick { startTicking() }
    }

    func disconnect() async {
        stopStreaming()
        tickTask?.cancel(); tickTask = nil
        camera.stopLive()
        if hw.recording != nil { await endRecording(reason: "Disconnected") }
        hw.streaming = false
        ledLit = false
        phoneOnGlassesWiFi = false
        linkState = .disconnected
        continuation.finish()
    }

    func send(_ frame: GlassesFrame) async throws {
        sentFrames.append(frame)
        onSent?(frame)
        if let reason = hw.unreachableReason, frame != .closeAssistant {
            throw refuse(frame, reason)
        }
        switch frame {
        case .enableWakeWord:
            feed.log(.glasses, "Wake word armed", detail: "“Hey Jarvis” · \(MetaGen2Profile.wakeLanguages.joined()) only", outcome: .info)
        case .showTranscript, .showAnswer:
            break      // Gen 2 has no display: the assistant state rides the session, nothing to draw
        case .setSpeaking(let on):
            hw.voiceActive = on
            speaking = on
            if on { listening = false; show(.speakers, .speaking, for: nil) } else { settleFocus() }
        case .closeAssistant:
            hw.voiceActive = false
            listening = false
            speaking = false
            settleFocus()
        case .capturePhoto(let question):
            try await takePhoto(source: .jarvis, question: question, emit: true)
        case .startVideo(let seconds):
            try await beginRecording(seconds: seconds, source: .jarvis)
        case .stopVideo:
            if hw.recording != nil { await endRecording(reason: nil) }
        case .startLiveStream:
            try await beginLive()
        case .stopLiveStream:
            endLive(reason: nil)
        case .speak(let text):
            if let reason = hw.audioRefusal() { throw refuse(frame, reason) }
            speaker?.say(text, volume: hw.volume)
            show(.speakers, .speaking, for: max(2, Double(text.count) / 14))
            feed.log(.jarvis, "Spoke on the glasses", detail: "“\(text)”")
        case .setVolume(let level):
            if let reason = hw.audioRefusal() { throw refuse(frame, reason) }
            hw.volume = max(0, min(level, 100))
            show(.speakers, .touch, for: 1.2)
            feed.log(.jarvis, "Volume \(hw.volume)%")
        case .setClipLength(let seconds):
            guard MetaGen2Profile.clipLengths.contains(seconds) else {
                throw refuse(frame, "Clip length must be one of \(MetaGen2Profile.clipLengths.map { "\($0) s" }.joined(separator: ", "))")
            }
            hw.clipLength = seconds
            feed.log(.sim, "Clip length \(seconds) s")
        case .setVideoMode(let mode):
            if hw.recording != nil { throw refuse(frame, "Can't change the video mode while recording") }
            hw.videoMode = mode
            feed.log(.sim, "Video mode \(mode.label)")
        case .enrolWakeWord(let phrase, let samples):
            if let reason = hw.voiceRefusal() { throw refuse(frame, reason) }
            guard samples.count == MetaGen2Profile.wakeEnrolSamples else {
                throw refuse(frame, "The glasses need exactly \(MetaGen2Profile.wakeEnrolSamples) samples of the phrase")
            }
            if let short = samples.firstIndex(where: { $0.count < 9_600 }) {
                throw refuse(frame, "Sample \(short + 1) is too short — say the whole phrase")
            }
            wakePhrase = phrase
            wakeDefaults?.set(phrase, forKey: "meta.sim.wakePhrase")
            feed.log(.glasses, "Wake word enrolled", detail: "“\(phrase)” · \(samples.count) samples · built on the glasses (US English)")
        }
    }

    // MARK: Camera

    private func takePhoto(source: MetaCommandFeed.Source, question: String?, emit: Bool) async throws {
        if let reason = hw.captureRefusal() { throw refuse(.capturePhoto(question: question), reason, source: source) }
        blinkLED()
        if source == .captureButton {
            // The button press shows first, then the lens.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.show(.camera, .capture, for: 1.3)
            }
        } else {
            show(.camera, .capture, for: 1.5)
        }
        let jpeg = try await camera.capturePhoto()
        hw.storePhoto()
        let thumb = Self.thumbnail(jpeg)
        let url = mediaDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try? jpeg.write(to: url)
        storage.insert(MetaStoredMedia(id: UUID(), kind: .photo, date: Date(), bytes: MetaGen2Profile.photoBytes,
                                       fileURL: url, thumbnail: thumb, source: camera.sourceName), at: 0)
        feed.log(source, "Photo", detail: [question.map { "“\($0)”" }, "\(MetaGen2Profile.photoWidth)×\(MetaGen2Profile.photoHeight) · \(camera.sourceName)"]
                    .compactMap { $0 }.joined(separator: " · "), thumbnail: thumb)
        if emit { continuation.yield(.photo(jpeg)) }
    }

    private func beginRecording(seconds requested: Int?, source: MetaCommandFeed.Source) async throws {
        if let reason = hw.videoRefusal() { throw refuse(.startVideo(seconds: requested ?? hw.clipLength), reason, source: source) }
        let seconds = hw.clipSeconds(requested: requested)
        hw.startRecording(seconds: seconds)
        ledLit = true
        show(.camera, .recording, for: nil)
        try? await camera.startRecording(mode: hw.videoMode, maxSeconds: seconds)
        let capped = (requested ?? seconds) > seconds ? " (capped by the \(hw.clipLength) s clip length)" : ""
        feed.log(source, "Recording started", detail: "\(hw.videoMode.label) · up to \(seconds) s\(capped) · \(camera.sourceName)")
    }

    /// Ends the clip in progress, stores it, and reports it up as `.video`.
    private func endRecording(reason: String?) async {
        guard let rec = hw.recording else { return }
        let kept = hw.finishRecording()
        if !hw.streaming { ledLit = false }
        let url = await camera.stopRecording()
        let bytes = Int64(rec.mode.bytesPerSecond * kept)
        storage.insert(MetaStoredMedia(id: UUID(), kind: .video, date: Date(), bytes: bytes, fileURL: url,
                                       thumbnail: nil, seconds: kept, mode: rec.mode, source: camera.sourceName), at: 0)
        settleFocus()
        let clip = MetaClip(seconds: kept, mode: rec.mode, bytes: bytes, fileURL: url, stopReason: reason)
        feed.log(.glasses, "Recording saved", detail: "\(Int(kept.rounded())) s · \(rec.mode.label)" + (reason.map { " · stopped: \($0)" } ?? ""),
                 outcome: reason == nil ? .done : .info)
        continuation.yield(.video(clip))
    }

    private func beginLive() async throws {
        if hw.streaming { return }
        if let reason = hw.captureRefusal(bytesNeeded: 0) { throw refuse(.startLiveStream, reason) }
        hw.streaming = true
        ledLit = true
        phoneOnGlassesWiFi = true
        show(.camera, .recording, for: nil)
        try? await camera.startLive { [weak self] frame in
            guard let self, self.hw.streaming else { return }
            self.latestLiveFrame = frame
            self.continuation.yield(.liveFrame(frame))
        }
        feed.log(.jarvis, "Live stream started", detail: "≤\(MetaGen2Profile.liveWidth)×\(MetaGen2Profile.liveHeight) @\(MetaGen2Profile.liveFPS) · phone joins the glasses' Wi-Fi")
    }

    private func endLive(reason: String?) {
        guard hw.streaming || reason != nil else { return }
        hw.streaming = false
        camera.stopLive()
        latestLiveFrame = nil
        phoneOnGlassesWiFi = false
        if hw.recording == nil { ledLit = false }
        settleFocus()
        feed.log(.glasses, "Live stream stopped", detail: reason, outcome: reason == nil ? .done : .info)
    }

    private func blinkLED() {
        ledLit = true
        ledBlinkTask?.cancel()
        ledBlinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.hw.recording == nil, !self.hw.streaming else { return }
            self.ledLit = false
        }
    }

    private func refuse(_ frame: GlassesFrame, _ reason: String, source: MetaCommandFeed.Source = .jarvis) -> MetaGlassesError {
        feed.log(source, Self.describe(frame), detail: reason, outcome: .refused(reason))
        return .refused(reason)
    }

    /// A fresh event stream for the next session (a stopped session finishes the old one).
    func renewInbound() {
        (inbound, continuation) = AsyncStream<GlassesInboundEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: Time

    private var pausedAt: Date?

    /// The app went to the background: stop the 1 s tick (no wakeups), remember when.
    func pauseTicking() {
        guard tickTask != nil else { return }
        tickTask?.cancel(); tickTask = nil
        pausedAt = Date()
    }

    /// Back in front: catch up the time that passed, then tick again.
    func resumeTicking() async {
        guard let pausedAt else { return }
        self.pausedAt = nil
        await advance(seconds: Date().timeIntervalSince(pausedAt))
        if autoTick { startTicking() }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.advance(seconds: 1)
            }
        }
    }

    /// Advance real time (the tick; tests call it directly).
    func advance(seconds: Double) async {
        let wasReachable = hw.unreachableReason == nil
        let before = hw.recording
        let events = hw.tick(seconds, speed: speed)
        await handle(events, recordingBefore: before)
        reconcileLink(wasReachable: wasReachable)
    }

    private func handle(_ events: [MetaHardwareState.Event], recordingBefore: MetaHardwareState.Recording?) async {
        for event in events {
            switch event {
            case .recordingStopped(let seconds, let reason):
                // The hardware model already closed and stored the recording; report the clip.
                await reportFinishedRecording(seconds: seconds, mode: recordingBefore?.mode ?? hw.videoMode, reason: reason)
            case .streamStopped(let reason):
                endLive(reason: reason)
            case .cameraTooHot:
                feed.log(.glasses, "Too hot — camera off", detail: "Back on once the glasses cool down", outcome: .info)
            case .cameraCooled:
                feed.log(.glasses, "Cooled down — camera back on", outcome: .info)
            case .poweredOff:
                feed.log(.glasses, "Battery empty — glasses off", outcome: .info)
            case .charged:
                feed.log(.glasses, "Fully charged", outcome: .info)
            }
        }
    }

    /// `MetaHardwareState` stores the clip when it stops a recording itself; mirror it here.
    private func reportFinishedRecording(seconds: Double, mode: MetaVideoMode, reason: String) async {
        if !hw.streaming { ledLit = false }
        settleFocus()
        let url = await camera.stopRecording()
        let bytes = Int64(mode.bytesPerSecond * seconds)
        storage.insert(MetaStoredMedia(id: UUID(), kind: .video, date: Date(), bytes: bytes, fileURL: url,
                                       thumbnail: nil, seconds: seconds, mode: mode, source: camera.sourceName), at: 0)
        feed.log(.glasses, "Recording saved", detail: "\(Int(seconds.rounded())) s · \(mode.label) · stopped: \(reason)", outcome: .info)
        continuation.yield(.video(MetaClip(seconds: seconds, mode: mode, bytes: bytes, fileURL: url,
                                           stopReason: reason.hasPrefix("Reached") ? nil : reason)))
    }

    /// Apply a change to the physical state and whatever it forces: covering the LED stops capture,
    /// folding ends audio and capture, leaving range drops the link.
    private func change(_ label: String, _ mutate: (inout MetaHardwareState) -> Void) async {
        let wasReachable = hw.unreachableReason == nil
        let before = hw.recording
        mutate(&hw)
        feed.log(.sim, label, outcome: .info)
        let events = hw.applyPhysicalChange()
        await handle(events, recordingBefore: before)
        reconcileLink(wasReachable: wasReachable)
    }

    private func reconcileLink(wasReachable: Bool) {
        let reachable = hw.unreachableReason == nil
        guard reachable != wasReachable, linkState != .disconnected || reachable else { return }
        if reachable {
            linkState = .ready
            continuation.yield(.linkState(.ready))
            feed.log(.glasses, "Link back", outcome: .info)
        } else {
            linkState = .disconnected
            continuation.yield(.linkState(.disconnected))
            feed.log(.glasses, "Link lost", detail: hw.unreachableReason, outcome: .info)
        }
    }

    // MARK: Sim controls (the glasses in your hand)

    func setWorn(_ on: Bool) async { await change(on ? "Put the glasses on" : "Took the glasses off") { $0.worn = on } }
    func setFolded(_ on: Bool) async { await change(on ? "Folded the glasses" : "Unfolded the glasses") { $0.folded = on; if !on { $0.inCase = false } } }
    func setInCase(_ on: Bool) async { await change(on ? "Put in the case" : "Took out of the case") { $0.inCase = on; if on { $0.folded = true } else { $0.folded = false } } }
    func setLEDCovered(_ on: Bool) async {
        await change(on ? "Covered the capture LED" : "Uncovered the capture LED") { $0.ledCovered = on }
        show(.led, .touch, for: 1.5)
    }
    func setInRange(_ on: Bool) async { await change(on ? "Back in range" : "Walked out of range") { $0.inRange = on } }
    func setMusicPlaying(_ on: Bool) async { await change(on ? "Music playing" : "Music stopped") { $0.musicPlaying = on } }
    func overrideBattery(_ percent: Double) async { await change("Battery set to \(Int(percent))%") { $0.battery = max(0, min(percent, 100)) } }
    func overrideHeat(_ value: Double) async {
        await change("Heat set to \(Int(value * 100))%") { $0.heat = max(0, min(value, 1)) }
        await advance(seconds: 0.001)    // let the too-hot / cooled rules react now
    }

    /// A touchpad gesture. The glasses act on it themselves first (defaults can't be suppressed),
    /// then report it up so the session starts Jarvis (hold) or runs a bound action.
    func touch(_ gesture: MetaTouchGesture) async {
        if let reason = hw.audioRefusal() {
            feed.log(.touch, MetaTouchBinding.label(gesture), detail: reason, outcome: .refused(reason))
            return
        }
        let action = MetaTouchBinding.defaultAction(for: gesture)
        var detail: String?
        switch action {
        case .playPause:
            hw.musicPlaying.toggle()
            detail = hw.musicPlaying ? "Playing track \(track)" : "Paused track \(track)"
            await mediaKeys?(.playPause)
        case .nextTrack:
            track += 1
            hw.musicPlaying = true
            detail = "Playing track \(track)"
            await mediaKeys?(.next)
        case .previousTrack:
            track = max(1, track - 1)
            hw.musicPlaying = true
            detail = "Playing track \(track)"
            await mediaKeys?(.previous)
        case .volumeUp:
            hw.volume = min(100, hw.volume + 10)
            detail = "Volume \(hw.volume)%"
        case .volumeDown:
            hw.volume = max(0, hw.volume - 10)
            detail = "Volume \(hw.volume)%"
        case .startAssistant, .endAssistant, .capturePhoto, .none:
            break
        }
        if let d = detail, action != .volumeUp, action != .volumeDown { detail = d + " (simulated music)" }
        feed.log(.touch, "\(MetaTouchBinding.label(gesture)) → \(MetaTouchBinding.label(action))", detail: detail)
        show(.touchpad, .touch, for: 1.2)
        continuation.yield(.touch(gesture))
    }

    /// The capture button on the right arm: a press takes a photo, a hold starts or stops a clip.
    /// The glasses do this themselves — the capture lands in glasses storage, not with Jarvis.
    func pressCaptureButton(hold: Bool) async {
        show(.captureButton, .touch, for: 1.0)
        do {
            if hold {
                if hw.recording != nil {
                    await endRecording(reason: nil)
                } else {
                    try await beginRecording(seconds: nil, source: .captureButton)
                }
            } else {
                try await takePhoto(source: .captureButton, question: nil, emit: false)
            }
        } catch {
            // refuse() already logged it
        }
    }

    /// The glasses fire "Hey Jarvis" (the on-glasses detector heard it).
    func wake() {
        if let reason = hw.voiceRefusal() {
            feed.log(.voice, "“Hey Jarvis”", detail: reason, outcome: .refused(reason))
            return
        }
        feed.log(.voice, "“Hey Jarvis”", detail: "Wake word heard on the glasses")
        listening = true
        show(.mic, .listening, for: nil)
        continuation.yield(.wake)
    }

    /// Import everything in glasses storage to the phone over the glasses' Wi-Fi — ~10 MB/s, and
    /// the phone leaves home Wi-Fi while it runs.
    func importAll() async {
        guard !storage.isEmpty else { return }
        if let reason = hw.unreachableReason ?? (hw.folded ? "The glasses are folded" : nil) {
            feed.log(.sim, "Import", detail: reason, outcome: .refused(reason))
            return
        }
        let items = storage
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        let seconds = MetaGen2Profile.wifiJoinSeconds + Double(bytes) / MetaGen2Profile.wifiBytesPerSecond
        phoneOnGlassesWiFi = true
        hw.wifiBusyFor = seconds
        feed.log(.sim, "Importing \(items.count) item\(items.count == 1 ? "" : "s")",
                 detail: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) over the glasses' Wi-Fi ≈ \(Int(seconds.rounded())) s", outcome: .info)
        let steps = 20
        for step in 1 ... steps {
            importProgress = Double(step) / Double(steps)
            if transferTimeScale > 0 { try? await Task.sleep(for: .seconds(seconds * transferTimeScale / Double(steps))) }
        }
        importProgress = nil
        imported.insert(contentsOf: items, at: 0)
        storage.removeAll { item in items.contains { $0.id == item.id } }
        hw.freeStorage(bytes: bytes, photos: items.filter { $0.kind == .photo }.count,
                       videos: items.filter { $0.kind == .video }.count)
        if !hw.streaming { phoneOnGlassesWiFi = false }
        feed.log(.glasses, "Imported \(items.count) item\(items.count == 1 ? "" : "s") to the phone")
    }

    // MARK: Focus (what the 3D model glides to)

    /// Hold to talk: your phone mic is the glasses' mics while you hold.
    func setHoldToTalk(_ on: Bool) {
        listening = on
        if on { show(.mic, .listening, for: nil) } else { settleFocus() }
    }

    /// Mark `part` for `seconds` (nil = until something settles it), then fall back to whatever is
    /// still going on.
    func show(_ part: MetaGlassesPart, _ pulse: MetaGlassesPulse, for seconds: Double?) {
        focus = MetaGlassesFocus(part: part, pulse: pulse)
        focusTask?.cancel()
        guard let seconds else { focusTask = nil; return }
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.settleFocus()
        }
    }

    /// The longest-running activity wins once a moment's mark ends.
    private func settleFocus() {
        focusTask?.cancel()
        focusTask = nil
        if hw.recording != nil || hw.streaming { focus = MetaGlassesFocus(part: .camera, pulse: .recording) }
        else if speaking { focus = MetaGlassesFocus(part: .speakers, pulse: .speaking) }
        else if listening { focus = MetaGlassesFocus(part: .mic, pulse: .listening) }
        else { focus = nil }
    }

    // MARK: Scripting (tests, the typed-prompt runner)

    func emit(_ event: GlassesInboundEvent) { continuation.yield(event) }
    func scriptWake() { emit(.wake) }
    func scriptSpokenPrompt(transcript: String, pcm: Data? = nil) {
        if let pcm { emit(.userAudio(pcm)) }
        emit(.userTranscript(text: transcript, isFinal: true))
    }
    func scriptCannedReply(_ text: String) { emit(.assistantAnswer(text: text, isFinal: true)) }
    func scriptTouch(_ gesture: MetaTouchGesture) { emit(.touch(gesture)) }
    func scriptLinkState(_ state: GlassesLinkState) { emit(.linkState(state)) }

    /// Stream spoken audio from the glasses mic the way real glasses do: `pcm` (16 kHz mono PCM16)
    /// in 40 ms frames at real-time pace, then silence — the mic stays open, and the voice engine's
    /// end-of-speech detector needs that quiet tail — until `stopStreaming()` or `silenceCap`.
    func streamSpokenAudio(_ pcm: Data, frameInterval: Duration = .milliseconds(40),
                           silenceCap: Duration = .seconds(15)) {
        stopStreaming()
        let frameBytes = Self.frameBytes
        streamTask = Task { [weak self] in
            var offset = pcm.startIndex
            while offset < pcm.endIndex {
                guard let self, !Task.isCancelled else { return }
                let end = min(offset + frameBytes, pcm.endIndex)
                self.emit(.userAudio(pcm.subdata(in: offset ..< end)))
                offset = end
                try? await Task.sleep(for: frameInterval)
            }
            let silence = Data(count: frameBytes)
            let clock = ContinuousClock()
            let quietFrom = clock.now
            while !Task.isCancelled, clock.now - quietFrom < silenceCap {
                guard let self else { return }
                self.emit(.userAudio(silence))
                try? await Task.sleep(for: frameInterval)
            }
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Helpers

    static func thumbnail(_ jpeg: Data, maxEdge: CGFloat = 160) -> Data? {
        downscaled(jpeg, maxEdge: maxEdge, quality: 0.7)
    }

    static func downscaled(_ jpeg: Data, maxEdge: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: quality)
    }

    static func describe(_ frame: GlassesFrame) -> String {
        switch frame {
        case .enableWakeWord: return "Arm wake word"
        case .showTranscript: return "Transcript"
        case .showAnswer: return "Answer"
        case .setSpeaking: return "Speaking"
        case .capturePhoto: return "Photo"
        case .closeAssistant: return "Close assistant"
        case .startVideo(let s): return "Record \(s) s"
        case .stopVideo: return "Stop recording"
        case .startLiveStream: return "Start live stream"
        case .stopLiveStream: return "Stop live stream"
        case .speak: return "Speak"
        case .setVolume(let v): return "Volume \(v)%"
        case .setClipLength(let s): return "Clip length \(s) s"
        case .setVideoMode(let m): return "Video mode \(m.label)"
        case .enrolWakeWord(let phrase, _): return "Enrol “\(phrase)”"
        }
    }
}
