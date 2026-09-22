import AVFoundation
import Foundation

/// The microphone for Live Jarvis: mono PCM16 little-endian at 16 kHz, captured
/// with Apple's voice processing **off**.
///
/// ## Why this is a second mic implementation and not a flag on the first
///
/// `DefaultAudioInput` on iOS does not own an engine at all — it taps
/// `VoiceAudioEngine.shared`, whose entire reason to exist is that the mic and the
/// reply's player sit on ONE engine with `setVoiceProcessingEnabled(true)`, so the
/// phone cancels its own speaker and barge-in can tell the user from the reply.
/// That is the right design for a conversation and the wrong one for a room:
///
///  * echo cancellation and noise suppression are trained to keep one near talker
///    and remove everything else, and "everything else" is precisely the distant
///    speakers Live mode exists to transcribe;
///  * the shared engine is a singleton with a `voiceProcessingUnavailable` latch,
///    a watchdog that restarts the mic, and a lifetime tied to a voice turn —
///    threading an "ambient" mode through it would put a branch in every one of
///    those paths, which is how the live voice turn would get broken by this task.
///
/// So ambient capture gets its own private engine and touches nothing the voice
/// stack owns. `VoiceAudioEngine.shared` is never referenced from this file. The
/// only shared thing is `AudioSessionArbiter`, which is the one writer of the
/// process-wide session by design, and Live takes its own `.ambient` claim there.
///
/// It conforms to `AudioInput` so `LiveStore` can be unit tested against the same
/// mock the voice tests already use.
@MainActor
final class AmbientAudioInput: AudioInput {

    /// ~85 ms at 48 kHz. Larger than the voice turn's 2048 (~43 ms): the ambient
    /// segmenter's shortest decision is an 800 ms silence, so a coarser frame costs
    /// nothing and halves the number of main-queue hops over an hours-long capture.
    static let tapBufferSize: AVAudioFrameCount = 4096

    /// A route change can stop the engine; a couple of attempts rides out the gap
    /// while iOS settles on the new input.
    static let startAttempts = 4
    static let retryDelayMs = 400

    var onFrame: ((Data) -> Void)?
    /// Fired when the audio route changed under us, so the session's
    /// `source_label` can be corrected mid-conversation.
    var onRouteChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var lastFrameAt = Date.distantPast
    private var generation = 0
    private var routeObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    /// The format the tap actually delivered, for the status line. "the wrong input
    /// is selected" and "the room is quiet" look identical without it.
    private(set) var hardwareDescription = "-"
    /// Loudest raw sample seen since the last read — evidence that the mic is
    /// alive even when nothing is loud enough to open an utterance.
    private(set) var rawPeak = 0.0

    /// A tap that has stopped delivering is not running, whatever the engine says.
    var isRunning: Bool {
        engine?.isRunning == true && Date().timeIntervalSince(lastFrameAt) < 3
    }

    func requestPermission() async -> Bool {
        #if os(iOS)
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    func start(sampleRate: Int) async throws {
        await stop()
        var lastError: Error?
        for attempt in 0..<Self.startAttempts {
            do {
                try Task.checkCancellation()
                try startEngine(sampleRate: sampleRate)
                observeRoute()
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                teardown()
                if attempt + 1 < Self.startAttempts {
                    try await Task.sleep(nanoseconds: UInt64(Self.retryDelayMs) * 1_000_000)
                }
            }
        }
        throw VoiceAudioError.micUnavailable(lastError?.localizedDescription
                                             ?? "the ambient engine would not start")
    }

    func stop() async {
        teardown()
    }

    /// Peak since the last call, then cleared — so the UI's level meter reads a
    /// window rather than an all-time high that never decays.
    func takeRawPeak() -> Double {
        defer { rawPeak = 0 }
        return rawPeak
    }

    // MARK: - Engine

    private func startEngine(sampleRate: Int) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Voice processing is NEVER enabled here. This absence is the feature —
        // see the class comment. It is also why the mixdown below must average
        // every channel instead of taking channel 0: with processing on, Apple
        // hands back one real channel padded with silence, and with it off every
        // channel of a mic array is live.

        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceAudioError.micUnavailable("no input route")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true)
        else { throw VoiceAudioError.formatUnsupported }

        // Handing `AVAudioConverter` a multi-channel source with no channel layout
        // yields digital ZERO — not an error, not noise — so the fold to mono is
        // ours and only the rate conversion is the converter's. (The same trap is
        // documented at length in `AudioInputEngine`; it cost a silent mic there.)
        let mixdown = hardware.channelCount > 1 && hardware.commonFormat == .pcmFormatFloat32
        let source = mixdown
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                            channels: 1, interleaved: false)
            : hardware
        guard let source, let converter = AVAudioConverter(from: source, to: target)
        else { throw VoiceAudioError.formatUnsupported }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        let ratio = Double(sampleRate) / hardware.sampleRate

        let tapGeneration = generation
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: hardware) { [weak self] buffer, _ in
            let peak = Self.peak(buffer)
            let mono = mixdown ? Self.monoAverage(buffer, to: source) : buffer
            guard let mono,
                  let data = Self.pcm16(mono, converter: converter, target: target, ratio: ratio),
                  !data.isEmpty else { return }
            // `DispatchQueue.main`, not `Task { @MainActor }`: frame ORDER decides
            // every timestamp in the transcript, and enqueue order onto an actor
            // is not guaranteed FIFO.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == tapGeneration else { return }
                    self.lastFrameAt = Date()
                    self.rawPeak = max(self.rawPeak, peak)
                    self.onFrame?(data)
                }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        lastFrameAt = Date()
        hardwareDescription = "\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch"
        JcLog.voice.notice("ambient mic started hw=\(self.hardwareDescription, privacy: .public) echoCancel=off")
    }

    /// A route change (AirPods in or out, a call ending) stops the engine without
    /// anybody calling `stop`. Restart it and tell the store, which relabels the
    /// session's capture source.
    private func observeRoute() {
        #if os(iOS)
        if routeObserver == nil {
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onRouteChange?() }
            }
        }
        #endif
        if configurationObserver == nil, let engine {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
            }
        }
    }

    private func restartAfterConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            lastFrameAt = Date()
            JcLog.voice.notice("ambient mic restarted after a route change")
        } catch {
            // Reported, not swallowed: the store's mic watchdog rebuilds from
            // scratch, and a capture that quietly stopped is the failure mode
            // design §8 forbids.
            JcLog.dropped(JcLog.voice, "restart ambient engine after route change", error)
        }
        onRouteChange?()
    }

    private func teardown() {
        generation += 1
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: - Render-thread helpers (must not touch actor state)

    /// Average every channel. With processing off, a mic array's channels are all
    /// live — the same sound a few centimetres apart — so the mean is the fold they
    /// want, and it also buys a little noise rejection for free.
    private nonisolated static func monoAverage(_ buffer: AVAudioPCMBuffer,
                                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData
        else { return nil }
        let frames = Int(buffer.frameLength)
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += input[c][i] }
            dst[0][i] = sum * scale
        }
        return out
    }

    private nonisolated static func peak(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = channels[c]
            // Every 16th sample: a peak detector does not need every one, and this
            // runs on the render thread.
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
                peak = max(peak, abs(samples[i]))
            }
        }
        return Double(peak)
    }

    private nonisolated static func pcm16(_ buffer: AVAudioPCMBuffer,
                                          converter: AVAudioConverter,
                                          target: AVAudioFormat,
                                          ratio: Double) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}

/// The ambient claim on `AVAudioSession`, mirroring
/// `DefaultAudioSessionControlling` for the voice stack: this class raises and
/// lowers a claim and never writes the session itself.
@MainActor
final class AmbientAudioSession {
    var onInterruption: ((AudioInterruption) -> Void)?

    /// `nonisolated(unsafe)` because `deinit` is nonisolated and has to release it.
    /// (`center` needs no such escape: it is a `let` of a `Sendable` type.)
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private let center: NotificationCenter
    private let arbiter: AudioSessionArbiter

    init(center: NotificationCenter = .default, arbiter: AudioSessionArbiter? = nil) {
        self.center = center
        self.arbiter = arbiter ?? .shared
        #if os(iOS)
        // A call or Siri taking the session is the pause/auto-resume path in
        // design §8, and it is the ONLY way an ambient capture legitimately stops
        // without the user asking.
        observer = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.onInterruption?(type == .began ? .began : .ended)
            }
        }
        #endif
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func hold() throws { try arbiter.hold(.ambient) }
    /// `reassert` after an interruption: iOS has deactivated us under the belief
    /// that we are still active.
    func reassert() throws { try arbiter.hold(.ambient, reassert: true) }
    /// DROPS the claim rather than deactivating — the keepalive may still hold the
    /// session, and pulling it out from under that costs the app its background
    /// allowance.
    func release() throws { try arbiter.release(.ambient) }
}
