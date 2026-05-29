import AVFoundation
import Foundation

/// Plays the JARVIS-voice reply clip (MP3 bytes from `transferFile`) through the
/// watch speaker / paired Bluetooth. Best-effort: the reply text is always
/// shown, so a playback failure is non-fatal.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?

    func play(data: Data) {
        guard !data.isEmpty else { return }
        let s = AVAudioSession.sharedInstance()
        // `.playback` (no `.longFormAudio`) routes to the watch speaker.
        do { try s.setCategory(.playback, mode: .default) } catch { return }
        // watchOS activates the audio session ASYNCHRONOUSLY; start playback in
        // the completion handler once the route is up. A synchronous
        // setActive(true) races route arbitration and often plays nothing.
        s.activate(options: []) { [weak self] success, error in
            guard success, error == nil else { return }
            do {
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                self?.player = p   // retain so playback isn't deallocated mid-clip
            } catch {
                // best-effort: the answer text is already on screen
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
