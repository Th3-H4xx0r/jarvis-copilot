import AVFoundation
import Foundation

/// The mic: an `AVAudioEngine` input tap resampled to mono PCM16 at the rate the
/// server wants (16 kHz). Replaces the Flutter `record` plugin.
///
/// Resampling HERE — rather than asking `AVAudioSession` for a 16 kHz rate — is
/// deliberate: changing the session's own sample rate is what used to drop the
/// loud speaker route back to the quiet earpiece mid-conversation.
@MainActor
final class DefaultAudioInput: AudioInput {

    /// Retry the engine start a few times. When the wake-word recognizer (or a
    /// just-ended turn) hasn't fully released the audio session yet, the first
    /// start throws "Session activation failed"; a short wait clears it.
    static let startAttempts = 5
    static let retryDelayMs = 350
    /// ~43 ms at 48 kHz hardware — small enough that the endpointer reacts
    /// promptly, large enough not to thrash the main queue.
    static let tapBufferSize: AVAudioFrameCount = 2048

    var onFrame: ((Data) -> Void)?
    /// An engine can stop on route changes without `stop()` being called. Also
    /// consider a tap that stopped delivering buffers unhealthy.
    var isRunning: Bool {
        engine?.isRunning == true && Date().timeIntervalSince(lastFrameAt) < 3
    }

    /// The tap's input format, for diagnostics. Set on start, read on the main
    /// actor when a line is written.
    nonisolated(unsafe) static var lastHardwareFormat = "-"
    /// Loudest sample the TAP saw, before any conversion. Compared against the
    /// converted peak it says whether silence came from the device or from us.
    nonisolated(unsafe) static var lastRawPeak = 0.0

    private var engine: AVAudioEngine?
    private var lastFrameAt = Date.distantPast
    private var generation = 0

    /// Ask for (or check) microphone access.
    ///
    /// The two platforms have DIFFERENT gates, and using the wrong one is silent
    /// rather than fatal. `AVAudioApplication` compiles on macOS and answers
    /// `.granted` there whatever TCC actually says — so the engine starts, the
    /// tap delivers buffers, every sample in them is zero, and the turn just
    /// never ends because the endpointer never hears speech. `AVCaptureDevice`
    /// is the microphone gate on macOS, and asking it is also what raises the
    /// system prompt.
    func requestPermission() async -> Bool {
        #if os(iOS)
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            // Denied or restricted. macOS will not prompt again, so the caller's
            // error message has to be the one that tells the user where to look.
            return false
        }
        #endif
    }

    /// The input the engine will actually read, for the diagnostics ring. Which
    /// device is selected is invisible from inside the app otherwise, and "the
    /// wrong input is selected" looks identical to "the user said nothing".
    nonisolated static var inputDescription: String {
        #if os(iOS)
        return "default"
        #else
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        #endif
    }

    /// What the OS says about the microphone right now, for the diagnostics ring.
    /// A live-but-silent mic is otherwise indistinguishable from a quiet room.
    nonisolated static var permissionDescription: String {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "undetermined"
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
        throw VoiceAudioError.micUnavailable(lastError?.localizedDescription ?? "engine would not start")
    }

    func stop() async {
        teardown()
    }

    // MARK: - Private

    private func startEngine(sampleRate: Int) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceAudioError.micUnavailable("no input route")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true)
        else { throw VoiceAudioError.formatUnsupported }

        // The MacBook's built-in mic is a THREE-channel array, and handing
        // `AVAudioConverter` a multi-channel source with no defined layout to
        // fold into mono produces silence — not an error, not noise, digital
        // zero. The engine runs, buffers arrive at the right rate and size,
        // every sample in them is 0, and the endpointer waits forever for
        // speech that is technically never there. (Measured on a 48 kHz/3 ch
        // input: raw tap peak 0.0056, converted peak 0.0000.)
        //
        // So the mixdown is ours, and only the sample rate is the converter's.
        // A plain average across the channels is what the array elements want:
        // they are the same sound a few centimetres apart.
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
            Self.lastRawPeak = max(Self.lastRawPeak, Self.rawPeak(buffer))
            let mono = mixdown ? Self.monoMixdown(buffer, to: source) : buffer
            guard let mono,
                  let data = Self.pcm16(mono, converter: converter, target: target, ratio: ratio),
                  !data.isEmpty else { return }
            // `DispatchQueue.main` and not `Task { @MainActor }`: frame ORDER is
            // audible (and the endpointer's budget depends on it), and Task
            // enqueue order onto an actor is not guaranteed FIFO.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == tapGeneration else { return }
                    self.lastFrameAt = Date()
                    self.onFrame?(data)
                }
            }
        }
        self.engine = engine
        engine.prepare()
        try engine.start()
        lastFrameAt = Date()
        Self.lastHardwareFormat = "\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch"
    }

    private func teardown() {
        generation += 1
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Average every channel of `buffer` into a one-channel buffer of `format`.
    /// Runs on the render thread, so it allocates only the output buffer and
    /// touches no actor state.
    private nonisolated static func monoMixdown(_ buffer: AVAudioPCMBuffer,
                                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData
        else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += input[c][i] }
            dst[0][i] = sum * scale
        }
        out.frameLength = buffer.frameLength
        return out
    }

    /// Loudest sample across every channel of one tap buffer.
    private nonisolated static func rawPeak(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = channels[c]
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
                peak = max(peak, abs(samples[i]))
            }
        }
        return Double(peak)
    }

    /// One tap buffer → mono PCM16 LE at the target rate. Runs on the render
    /// thread, so it must not touch actor state.
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
