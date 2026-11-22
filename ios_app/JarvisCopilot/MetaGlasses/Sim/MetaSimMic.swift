import AVFoundation

/// Hold to talk to the simulated glasses: records your voice with the phone mic while held, as
/// 16 kHz mono PCM16 — what the glasses' mic array hands the phone. The recording finishes before
/// the voice turn starts, so the phone mic is never open alongside the voice engine.
@MainActor
final class MetaSimMic: ObservableObject {
    @Published private(set) var recording = false
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var holdsSession = false

    func start() async throws {
        guard !recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MetaGlassesError.transportUnavailable("microphone permission is off")
        }
        try AudioSessionArbiter.shared.hold(.recording)
        holdsSession = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-sim-mic-\(UUID().uuidString).wav")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard recorder.record() else {
            release()
            throw MetaGlassesError.transportUnavailable("the recorder refused to start")
        }
        self.recorder = recorder
        self.url = url
        recording = true
    }

    /// Stop and hand back the PCM (empty if nothing was recorded).
    func stop() -> Data {
        recorder?.stop()
        recorder = nil
        recording = false
        release()
        guard let url else { return Data() }
        self.url = nil
        defer { try? FileManager.default.removeItem(at: url) }
        return Self.pcm(fromWAV: url) ?? Data()
    }

    func cancel() { _ = stop() }

    private func release() {
        guard holdsSession else { return }
        holdsSession = false
        try? AudioSessionArbiter.shared.release(.recording)
    }

    /// The samples of a 16-bit WAV file.
    static func pcm(fromWAV url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
    }
}
