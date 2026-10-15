import Accelerate
import AVFoundation

/// The wake word's microphone: an AVAudioEngine tap that runs the energy VAD on
/// every buffer and hands the recognizer 16 kHz mono audio only while someone
/// speaks, with ~0.5 s of pre-roll so the start of "Hey" isn't lost.
///
/// Threads: `start` / `stop` / `resetVAD` on the main thread; the callbacks
/// `onVoiceStart` / `onVoiceEnd` / `onConfigChange` arrive on the main thread,
/// `onBuffer` on the audio thread.
/// After coucou's VoiceAudio (github.com/Louis-CFM/coucou, MIT).
final class WakeAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    private var converter: AVAudioConverter?

    // Audio thread only.
    private var vad = EnergyVAD()
    private var tunedFrameLength: AVAudioFrameCount = 0

    private let prerollLock = NSLock()
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private var prerollCapacity = 22

    /// Last time a buffer came through (the watchdog reads it on main).
    private let timeLock = NSLock()
    private var _lastBufferTime = Date.distantPast
    var lastBufferTime: Date { timeLock.withLock { _lastBufferTime } }

    private let resetLock = NSLock()
    private var pendingVADReset = false

    var onVoiceStart: (() -> Void)?
    var onVoiceEnd: (() -> Void)?
    /// Called on the audio thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onConfigChange: (() -> Void)?

    func start() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "JarvisWake", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input."])
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        if let conv = AVAudioConverter(from: format, to: target) {
            conv.primeMethod = .none
            conv.downmix = true
            converter = conv
        }
        Self.installTap(on: input, format: format, owner: self)
        tapInstalled = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigChange?() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard tapInstalled else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        converter = nil
        prerollLock.withLock { prerollBuffers.removeAll() }
    }

    func resetVAD() { resetLock.withLock { pendingVADReset = true } }

    func drainPreroll() -> [AVAudioPCMBuffer] {
        prerollLock.withLock {
            let snap = prerollBuffers
            prerollBuffers.removeAll()
            return snap
        }
    }

    // MARK: audio thread

    private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, owner: WakeAudio) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak owner] buf, _ in
            owner?.process(buf)
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        timeLock.withLock { _lastBufferTime = Date() }
        if buf.frameLength > 0,
           abs(Double(buf.frameLength) - Double(tunedFrameLength)) > Double(tunedFrameLength) * 0.05 {
            tunedFrameLength = buf.frameLength
            let fps = buf.format.sampleRate / Double(buf.frameLength)
            vad.setFrameRate(fps)
            prerollLock.withLock { prerollCapacity = max(2, Int((0.5 * fps).rounded(.up))) }
        }
        if resetLock.withLock({ () -> Bool in
            let r = pendingVADReset
            pendingVADReset = false
            return r
        }) {
            vad.reset()
        }
        let deliver = convert(buf) ?? buf
        prerollLock.withLock {
            while prerollBuffers.count >= prerollCapacity { prerollBuffers.removeFirst() }
            prerollBuffers.append(deliver)
        }
        switch vad.feed(Self.meanSquarePower(buf)) {
        case .start: DispatchQueue.main.async { [weak self] in self?.onVoiceStart?() }
        case .end: DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        case .none: break
        }
        if vad.isActive { onBuffer?(deliver) }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conv = converter else { return nil }
        let ratio = conv.outputFormat.sampleRate / buf.format.sampleRate
        let frames = AVAudioFrameCount(ceil(Double(buf.frameLength) * ratio)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: max(1, frames)) else { return nil }
        var provided = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            guard !provided else { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buf
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    static func meanSquarePower(_ buf: AVAudioPCMBuffer) -> Double {
        guard let data = buf.floatChannelData, buf.frameLength > 0 else { return 0 }
        let frames = vDSP_Length(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        guard channels > 0 else { return 0 }
        if buf.format.isInterleaved {
            var ms: Float = 0
            vDSP_measqv(data[0], 1, &ms, frames * vDSP_Length(channels))
            return Double(ms)
        }
        var sum = 0.0
        for ch in 0..<channels {
            var ms: Float = 0
            vDSP_measqv(data[ch], 1, &ms, frames)
            sum += Double(ms)
        }
        return sum / Double(channels)
    }
}
