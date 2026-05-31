import AVFoundation
import Foundation

/// Plays the JARVIS-voice reply clip (MP3 delivered via WCSession `transferFile`)
/// through the watch speaker. The Volume drawer keeps the MEDIA volume route
/// active for the Digital Crown WITHOUT interrupting a reply that's already
/// speaking, and WITHOUT any audible tone.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?
    private var calibrating = false   // true only while the silent volume loop owns `player`

    func play(base64 string: String) {
        guard let data = Data(base64Encoded: string), !data.isEmpty else {
            VoiceStatus.shared.set("🔇 bad clip data"); return
        }
        play(data: data)
    }

    func play(data: Data) {
        calibrating = false           // a real reply clip takes over the player
        start(data: data, loop: false)
    }

    /// Keep the MEDIA volume route active while the Volume drawer is open so the
    /// Digital Crown adjusts media (not ring) volume.
    /// - If a reply clip is already playing, IT is the active media — leave it
    ///   alone (no interruption, no tone).
    /// - Otherwise loop a SILENT buffer so the crown still has media to grab,
    ///   with no audible beep.
    func beginVolumeCalibration() {
        if let p = player, p.isPlaying, !calibrating { return }   // don't interrupt the reply
        calibrating = true
        start(data: AudioPlayer.makeSilentLoop(), loop: true)
    }
    func endVolumeCalibration() {
        // Only stop the silent calibration loop — NEVER the speaking reply clip.
        guard calibrating else { return }
        calibrating = false
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

    // MARK: - Silent volume-calibration loop (in-memory 16-bit mono PCM WAV)
    /// A short SILENT buffer. Looping it keeps an AVAudioPlayer "playing" so the
    /// Digital Crown adjusts the media-volume route — with no audible tone.
    private static func makeSilentLoop() -> Data {
        let sr = 44_100
        let n = sr / 5                                    // 0.2s of silence
        return wav(pcm: Data(count: n * 2), sampleRate: sr)   // all-zero PCM = silence
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
