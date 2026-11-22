import AVFoundation

/// Listens for one question, the way the glasses' mics do once their assistant opens.
@MainActor
protocol MetaQuestionCapturing: AnyObject {
    /// Records until the speaker stops (≈1 s quiet; waits ≤4 s for them to start, ≤10 s total).
    /// 16 kHz mono PCM16; empty when nobody spoke.
    func captureQuestion() async throws -> Data
}

/// The phone mic standing in for the glasses' mics, with a level meter to hear when you stop.
@MainActor
final class MetaPhoneQuestionCapture: MetaQuestionCapturing {
    /// Below this (dBFS) counts as quiet.
    static let speechThreshold: Float = -38

    func captureQuestion() async throws -> Data {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MetaGlassesError.transportUnavailable("microphone permission is off")
        }
        try AudioSessionArbiter.shared.hold(.recording)
        MetaGlassesHaptics.allowWhileRecording(true)
        defer {
            MetaGlassesHaptics.allowWhileRecording(false)
            try? AudioSessionArbiter.shared.release(.recording)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-sim-ask-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var recorder: AVAudioRecorder?
        for rate in [16_000.0, 44_100.0] {
            if let r = try? AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]) {
                r.isMeteringEnabled = true
                if r.prepareToRecord(), r.record() { recorder = r; break }
            }
        }
        guard let recorder else { throw MetaGlassesError.transportUnavailable("the microphone wouldn't start recording") }
        let clock = ContinuousClock()
        let began = clock.now
        var spoke = false
        var lastLoud = clock.now
        while clock.now - began < .seconds(10) {
            try? await Task.sleep(for: .milliseconds(100))
            recorder.updateMeters()
            if recorder.averagePower(forChannel: 0) > Self.speechThreshold { spoke = true; lastLoud = clock.now }
            if spoke, clock.now - lastLoud > .seconds(1) { break }
            if !spoke, clock.now - began > .seconds(4) { break }
        }
        recorder.stop()
        guard spoke else { return Data() }
        return MetaSimMic.pcm16k(from: url) ?? Data()
    }
}
