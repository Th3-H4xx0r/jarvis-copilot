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
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?

    private(set) var voiceProcessing = false
    /// Set once processing delivered no mic audio on this route. For the rest of
    /// THIS conversation only: latched for the whole launch, one slow start
    /// silently took echo cancellation away from every conversation after it.
    private(set) var voiceProcessingUnavailable = false

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
        let format = try graph().inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceAudioError.micUnavailable("no input route")
        }
        return format
    }

    func startMic(bufferSize: AVAudioFrameCount,
                  tap: @escaping AVAudioNodeTapBlock) throws {
        let engine = try graph()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: input.outputFormat(forBus: 0), block: tap)
        micInUse = true
        try run(engine)
    }

    func stopMic() {
        engine?.inputNode.removeTap(onBus: 0)
        micInUse = false
        releaseIfIdle()
    }

    // MARK: - Reply stream

    func startStream(sampleRate: Int, onLevel: @escaping (Double) -> Void) throws {
        let engine = try graph()
        try connectPlayer(rate: sampleRate, in: engine)
        onRenderLevel = onLevel
        streamInUse = true
        try run(engine)
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

    private func graph() throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // The playback path exists before processing is switched on, so the
        // output side it enables has the reply as its reference from the start.
        guard let format = Self.floatMono(Self.defaultStreamRate) else { throw VoiceAudioError.formatUnsupported }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        var processed = false
        if !voiceProcessingUnavailable {
            do {
                try input.setVoiceProcessingEnabled(true)
                processed = true
            } catch {
                JcLog.dropped(JcLog.voice, "enable voice processing", error)
            }
        }
        let ioFormat = processed ? input.outputFormat(forBus: 0) : engine.outputNode.inputFormat(forBus: 0)
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
            engine.inputNode.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
            player?.stop()
            engine.stop()
        }
        engine = nil
        player = nil
        playerFormat = nil
        voiceProcessing = false
    }

    private static func floatMono(_ rate: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)
    }
}
