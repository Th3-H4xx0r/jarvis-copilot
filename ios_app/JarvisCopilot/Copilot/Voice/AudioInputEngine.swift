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

    private var engine: AVAudioEngine?
    private var lastFrameAt = Date.distantPast
    private var generation = 0

    func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
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
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hardware, to: target)
        else { throw VoiceAudioError.formatUnsupported }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        let ratio = Double(sampleRate) / hardware.sampleRate

        let tapGeneration = generation
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: hardware) { [weak self] buffer, _ in
            guard let data = Self.pcm16(buffer, converter: converter, target: target, ratio: ratio),
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
    }

    private func teardown() {
        generation += 1
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
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
