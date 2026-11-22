import AVFoundation

/// Listens for one question, the way the glasses' mics do once their assistant opens.
@MainActor
protocol MetaQuestionCapturing: AnyObject {
    /// Records until the speaker stops (≈1 s quiet; waits ≤4 s for them to start, ≤10 s total).
    /// 16 kHz mono PCM16; empty when nobody spoke. `beforeRelease` runs while the mic is still held
    /// (the done chime) and returns how many ms to keep holding it so the sound isn't cut off.
    func captureQuestion(beforeRelease: (() -> Int)?) async throws -> Data
}

/// The phone mic standing in for the glasses' mics, with a level meter to hear when you stop.
@MainActor
final class MetaPhoneQuestionCapture: MetaQuestionCapturing {
    /// Below this (dBFS) counts as quiet.
    static let speechThreshold: Float = -38
    /// The simulator already holds `.glassesSim` for the whole assistant turn; a standalone capture
    /// takes it itself.
    let claimsSession: Bool

    init(claimsSession: Bool = false) {
        self.claimsSession = claimsSession
    }

    func captureQuestion(beforeRelease: (() -> Int)?) async throws -> Data {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MetaGlassesError.transportUnavailable("microphone permission is off")
        }
        if claimsSession { try AudioSessionArbiter.shared.hold(.glassesSim) }
        MetaGlassesHaptics.allowWhileRecording(true)
        defer {
            MetaGlassesHaptics.allowWhileRecording(false)
            if claimsSession { try? AudioSessionArbiter.shared.release(.glassesSim) }
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
        // Chime while the session is still ours: releasing it switches/deactivates the audio
        // session, which stopped the done chime mid-play (2026-11-22).
        let holdMs = beforeRelease?() ?? 0
        if holdMs > 0 { try? await Task.sleep(for: .milliseconds(holdMs)) }
        guard spoke else { return Data() }
        return MetaSimMic.pcm16k(from: url) ?? Data()
    }
}
