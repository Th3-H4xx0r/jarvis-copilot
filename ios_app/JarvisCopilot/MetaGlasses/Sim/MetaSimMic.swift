import AVFoundation

/// Hold to talk to the simulated glasses: records your voice with the phone mic while held, as
/// 16 kHz mono PCM16 — what the glasses' mic array hands the phone. The recording finishes before
/// the voice turn starts, so the phone mic is never open alongside the voice engine.
///
/// One recorder per press: a press gesture reports every finger movement, and starting a second
/// recorder while the first held the mic failed with "the recorder refused to start" (2026-11-22).
@MainActor
final class MetaSimMic: ObservableObject {
    @Published private(set) var recording = false
    private var starting = false
    /// Released before the recorder came up: stop it as soon as it does.
    private var releasedEarly = false
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var holdsSession = false

    /// Begin recording (no-op while one is starting or running).
    func start() async throws {
        guard !recording, !starting else { return }
        starting = true
        releasedEarly = false
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MetaGlassesError.transportUnavailable("microphone permission is off")
        }
        try AudioSessionArbiter.shared.hold(.recording)
        holdsSession = true
        // 16 kHz first; some routes refuse it, so fall back to 44.1 kHz and convert on read.
        for rate in [16_000.0, 44_100.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-sim-mic-\(UUID().uuidString).wav")
            guard let recorder = try? AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]), recorder.prepareToRecord(), recorder.record() else { continue }
            self.recorder = recorder
            self.url = url
            recording = true
            if releasedEarly { return }   // stop() is called by finishPress
            return
        }
        release()
        throw MetaGlassesError.transportUnavailable("the microphone wouldn't start recording")
    }

    /// The finger lifted. Returns the PCM, or nil when the recorder never came up (released while
    /// still starting — the next start() call is cancelled by the flag).
    func finishPress() -> Data? {
        if starting { releasedEarly = true; return nil }
        guard recording else { return nil }
        return stop()
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
        return Self.pcm16k(from: url) ?? Data()
    }

    func cancel() { _ = stop() }

    private func release() {
        guard holdsSession else { return }
        holdsSession = false
        try? AudioSessionArbiter.shared.release(.recording)
    }

    /// The file's audio as 16 kHz mono Int16, converting from whatever rate it was recorded at.
    nonisolated static func pcm16k(from url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }
}
