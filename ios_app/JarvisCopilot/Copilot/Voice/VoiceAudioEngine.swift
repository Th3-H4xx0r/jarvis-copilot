import AVFoundation
import Foundation

/// The phone's conversation audio: the microphone AND the reply's player on ONE
/// `AVAudioEngine`, with Apple's voice processing switched on.
///
/// Echo cancellation can only take out what it can see. Voice processing is a
/// property of an engine's paired input and output nodes: it subtracts what
/// THAT engine plays from what its mic hears. The reply used to play on a
/// second engine, so the canceller never had the reply as its reference — at
/// normal volume the room swallowed most of it, but turned up, the mic heard
/// the reply loud enough that no level threshold could tell it from someone
/// talking over it. Barge-in either missed people or interrupted itself.
/// Playing the reply here is how a call app does it: the phone cancels its own
/// speaker, and what is left in the mic is the person.
///
/// The graph follows `AVAudioIONode.h`: voice processing is toggled only while
/// the engine is stopped; the mic is tapped in the input node's OUTPUT format
/// (the hardware format never delivers once processing is on); and the mixer
/// feeds the output node in that same voice-processing format — left to the
/// route's own format, the engine reports running while the tap never fires.
/// A route where processing still delivers nothing is caught by the mic's
/// watchdog, which calls `giveUpVoiceProcessing()` and restarts without it.
///
/// The engine lives while the mic or the reply stream needs it, and is released
/// — voice processing with it — when neither does.
@MainActor
final class VoiceAudioEngine {
    static let shared = VoiceAudioEngine()

    private var engine: AVAudioEngine?
    private var microphoneNode: AVAudioInputNode?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?

    private(set) var voiceProcessing = false
    /// Set once processing delivered no mic audio on this route. For the rest of
    /// THIS conversation only: latched for the whole launch, one slow start
    /// silently took echo cancellation away from every conversation after it.
    private(set) var voiceProcessingUnavailable = false

    /// Build the next engine without voice processing. The Mac's push to talk
    /// sets it: nothing plays while the key is held (holding it over a reply
    /// stops the reply), and the voice-processing unit takes 0.4–0.9 s to build
    /// — on the main thread, which froze the island opening around it — where
    /// a plain mic starts in ~50 ms. Kept per engine: the next one built after
    /// it's cleared has echo cancellation again.
    var skipVoiceProcessing = false

    /// Build the next engine with no mic at all: the glasses' talk, whose words come
    /// over Bluetooth and whose reply is all this plays. Its session used to be
    /// playback-only, so no mic half was ever built; under the armed keepalive's
    /// recordable session it would build the phone's mic and echo cancellation (and
    /// VoiceChat mode) for nothing. Set by the voice store for that talk.
    var playbackOnly = false

    /// Engine events for the voice diagnostics (the store points this at `note`).
    var onEvent: ((String) -> Void)?

    private var micInUse = false
    private var streamInUse = false
    private var onRenderLevel: ((Double) -> Void)?

    /// The reply's rate. The server speaks 24 kHz PCM.
    static let defaultStreamRate = 24000

    var isRunning: Bool { engine?.isRunning == true }

    var outputPresentationLatency: TimeInterval { engine?.outputNode.presentationLatency ?? 0 }

    // MARK: - Mic

    /// The format the mic tap delivers: mono, voice-processed, at the I/O rate.
    func micFormat() throws -> AVAudioFormat {
        _ = try graphWithMic()
        guard let microphoneNode else { throw VoiceAudioError.micUnavailable("audio session does not permit microphone capture") }
        let format = microphoneNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceAudioError.micUnavailable("no input route")
        }
        return format
    }

    func startMic(bufferSize: AVAudioFrameCount,
                  tap: @escaping AVAudioNodeTapBlock) throws {
        let engine = try graphWithMic()
        guard let input = microphoneNode else { throw VoiceAudioError.micUnavailable("audio session does not permit microphone capture") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: input.outputFormat(forBus: 0), block: tap)
        micInUse = true
        do { try run(engine) } catch {
            // A mic that never started must not hold the engine (see `startStream`).
            input.removeTap(onBus: 0)
            micInUse = false
            releaseIfIdle()
            throw error
        }
    }

    func stopMic() {
        microphoneNode?.removeTap(onBus: 0)
        micInUse = false
        releaseIfIdle()
    }

    // MARK: - Reply stream

    func startStream(sampleRate: Int, onLevel: @escaping (Double) -> Void) throws {
        let engine = try graph()
        try connectPlayer(rate: sampleRate, in: engine)
        onRenderLevel = onLevel
        streamInUse = true
        do { try run(engine) } catch {
            // A stream that never started must not hold the engine: left "in use",
            // nothing ever released it, and whatever session it was built for (one
            // with no mic) stuck for the rest of the launch.
            streamInUse = false
            onRenderLevel = nil
            releaseIfIdle()
            throw error
        }
        player?.play()
    }

    /// The reply's format, for building buffers.
    var streamFormat: AVAudioFormat? { streamInUse ? playerFormat : nil }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard let engine, let player, streamInUse else { return }
        if !engine.isRunning {
            // An interruption or a media-services reset stopped us; bring it back.
            do { try run(engine) } catch {
                JcLog.dropped(JcLog.voice, "restart conversation engine", error)
                return
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// The player's volume. The mixer after it is what voice processing takes
    /// as its reference, so the canceller follows a turned-down reply.
    var replyVolume: Float = 1 {
        didSet { player?.volume = replyVolume }
    }

    /// Drop what is queued and keep playing whatever comes next (barge-in).
    func flushStream() {
        player?.stop()
        if streamInUse { player?.play() }
    }

    func stopStream() {
        player?.stop()
        streamInUse = false
        onRenderLevel = nil
        releaseIfIdle()
    }

    // MARK: - Fallback

    /// Voice processing delivered no mic audio on this route: rebuild without it
    /// for the rest of the launch. A running reply stream is carried over; the
    /// mic's caller restarts the mic, whose format changes with this.
    func giveUpVoiceProcessing() {
        guard !voiceProcessingUnavailable else { return }
        voiceProcessingUnavailable = true
        let resumeStream = streamInUse
        let rate = Int(playerFormat?.sampleRate ?? Double(Self.defaultStreamRate))
        let level = onRenderLevel
        tearDown()
        micInUse = false
        streamInUse = false
        if resumeStream, let level {
            do { try startStream(sampleRate: rate, onLevel: level) } catch {
                JcLog.dropped(JcLog.voice, "resume reply stream without voice processing", error)
            }
        }
        JcLog.voice.notice("voice processing gave no mic audio; continuing without it")
        onEvent?("echo cancellation gave no mic audio; continuing this conversation without it")
    }

    // MARK: - Graph

    /// The engine, with a mic. One built while the session could only play — the
    /// glasses' playback-only session, a reply with no voice claim — has none, and
    /// kept alive by that reply it failed every mic start after it ("audio session
    /// does not permit microphone capture") until Jarvis was killed. Once the
    /// session records it is rebuilt, the reply it was playing carried over.
    private func graphWithMic() throws -> AVAudioEngine {
        let engine = try graph()
        guard microphoneNode == nil, Self.sessionPermitsMicrophone else { return engine }
        onEvent?("audio engine had no mic (built for playback only); rebuilding with one")
        let resumeStream = streamInUse
        let rate = Int(playerFormat?.sampleRate ?? Double(Self.defaultStreamRate))
        let level = onRenderLevel
        tearDown()
        streamInUse = false
        _ = try graph()
        if resumeStream, let level {
            do { try startStream(sampleRate: rate, onLevel: level) } catch {
                JcLog.dropped(JcLog.voice, "resume reply stream after rebuilding for the mic", error)
            }
        }
        // Again: a reply that failed to resume released the engine just rebuilt.
        return try graph()
    }

    /// Whether the session's category records; only then may the graph build its
    /// input half (see `graph()`).
    private static var sessionPermitsMicrophone: Bool {
        #if os(iOS)
        let category = AVAudioSession.sharedInstance().category
        return category == .playAndRecord || category == .record
        #else
        return true
        #endif
    }

    private func graph() throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        // Wearable PCM arrives over Bluetooth; its audio session is playback
        // only. Creating an input node and enabling VoiceProcessingIO here can
        // raise an Objective-C exception (not catchable with Swift do/catch).
        // Only microphone-capable sessions may build that half of the graph.
        let input = Self.sessionPermitsMicrophone && !playbackOnly ? engine.inputNode : nil
        let player = AVAudioPlayerNode()
        player.volume = replyVolume
        engine.attach(player)
        // The playback path exists before processing is switched on, so the
        // output side it enables has the reply as its reference from the start.
        guard let format = Self.floatMono(Self.defaultStreamRate) else { throw VoiceAudioError.formatUnsupported }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        var processed = false
        if let input, !voiceProcessingUnavailable, !skipVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                processed = true
            } catch {
                JcLog.dropped(JcLog.voice, "enable voice processing", error)
            }
        }
        let ioFormat = processed ? input!.outputFormat(forBus: 0) : engine.outputNode.inputFormat(forBus: 0)
        if ioFormat.sampleRate > 0, ioFormat.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: ioFormat)
        }
        // The orb follows what is actually rendered, pauses between words
        // included, not what arrives from the network.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let level = DefaultAudioOutput.peakAmplitude(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onRenderLevel?(level) }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        self.engine = engine
        self.microphoneNode = input
        self.player = player
        playerFormat = format
        voiceProcessing = processed
        JcLog.voice.notice("conversation engine: voice processing \(processed ? "on" : "off", privacy: .public), io \(Int(ioFormat.sampleRate))Hz/\(ioFormat.channelCount)ch")
        onEvent?("audio engine built: echoCancel=\(processed ? "on" : "off") io=\(Int(ioFormat.sampleRate))Hz/\(ioFormat.channelCount)ch")
        return engine
    }

    private func connectPlayer(rate: Int, in engine: AVAudioEngine) throws {
        guard let player else { return }
        if let playerFormat, Int(playerFormat.sampleRate) == rate { return }
        guard let format = Self.floatMono(rate) else { throw VoiceAudioError.formatUnsupported }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
    }

    private func run(_ engine: AVAudioEngine) throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// A route change (headphones, Bluetooth, the speaker toggle) stops the engine.
    private func configurationChanged() {
        guard let engine, !engine.isRunning, micInUse || streamInUse else { return }
        onEvent?("audio route changed; restarting engine")
        do {
            try run(engine)
            if streamInUse { player?.play() }
        } catch {
            JcLog.dropped(JcLog.voice, "restart conversation engine after route change", error)
        }
    }

    private func releaseIfIdle() {
        guard !micInUse, !streamInUse else { return }
        tearDown()
        // The conversation is over: the next one tries echo cancellation again.
        voiceProcessingUnavailable = false
    }

    private func tearDown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            microphoneNode?.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
            player?.stop()
            engine.stop()
        }
        engine = nil
        microphoneNode = nil
        player = nil
        playerFormat = nil
        voiceProcessing = false
    }

    private static func floatMono(_ rate: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)
    }
}
