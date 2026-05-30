import AVFoundation
import Foundation

/// Plays the JARVIS-voice reply clip (MP3 delivered via WCSession `transferFile`)
/// through the watch speaker. The Volume drawer plays a soft looping TEST TONE
/// (not the reply) so the Digital Crown has active audio to adjust.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?

    func play(base64 string: String) {
        guard let data = Data(base64Encoded: string), !data.isEmpty else {
            VoiceStatus.shared.set("🔇 bad clip data"); return
        }
        play(data: data)
    }

    func play(data: Data) {
        start(data: data, loop: false)
    }

    /// Loop a gentle test tone while the Volume drawer is open, so the Digital
    /// Crown adjusts the MEDIA volume (it only does so while audio is playing).
    func beginVolumeCalibration() {
        start(data: AudioPlayer.makeTone(), loop: true)
    }
    func endVolumeCalibration() {
        player?.stop()
        player = nil
    }

    private func start(data: Data, loop: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default)
        } catch {
            VoiceStatus.shared.set("🔇 \(error.localizedDescription)")
            return
        }
        s.activate(options: []) { success, error in
            Task { @MainActor in
                guard success, error == nil else {
                    VoiceStatus.shared.set("🔇 audio session unavailable")
                    return
                }
                do {
                    let p = try AVAudioPlayer(data: data)
                    p.delegate = self
                    p.volume = 1.0
                    p.numberOfLoops = loop ? -1 : 0
                    p.prepareToPlay()
                    p.play()
                    self.player = p
                    VoiceStatus.shared.set("")   // clean on success
                } catch {
                    VoiceStatus.shared.set("🔇 \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.player = nil }
    }

    // MARK: - Generated test tone (in-memory 16-bit mono PCM WAV)
    /// A bell-like "ding" (bright fundamental + inharmonic partials, exponential
    /// ring-out) followed by a short gap, so looping yields a gentle
    /// "ding … ding …" similar to the watchOS volume-change sound.
    private static func makeTone() -> Data {
        let sr = 44_100.0
        let ringDur = 0.5
        let gapDur = 0.42
        let f0 = 1046.5                                   // C6 — bright, bell-like
        let partials: [(mult: Double, amp: Double)] = [(1.0, 1.0), (2.0, 0.5), (2.76, 0.28)]
        let amp = 0.24
        let ringN = Int(sr * ringDur)
        let gapN = Int(sr * gapDur)
        var pcm = Data(capacity: (ringN + gapN) * 2)
        for i in 0..<ringN {
            let t = Double(i) / sr
            let env = exp(-t * 7.0)                       // exponential ring-out
            var v = 0.0
            for p in partials { v += sin(2.0 * Double.pi * f0 * p.mult * t) * p.amp }
            v *= env * amp
            var sample = Int16(max(-1.0, min(1.0, v)) * 32_767.0).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        pcm.append(Data(count: gapN * 2))                 // trailing silence between dings
        return wav(pcm: pcm, sampleRate: Int(sr))
    }

    private static func wav(pcm: Data, sampleRate: Int) -> Data {
        func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
        func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
        var d = Data()
        d.append("RIFF".data(using: .ascii)!); d.append(u32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); d.append(u32(16)); d.append(u16(1)); d.append(u16(1))
        d.append(u32(sampleRate)); d.append(u32(sampleRate * 2)); d.append(u16(2)); d.append(u16(16))
        d.append("data".data(using: .ascii)!); d.append(u32(pcm.count)); d.append(pcm)
        return d
    }
}
