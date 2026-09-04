import AVFoundation
import Combine
import Foundation

/// Plays the JARVIS-voice reply clip (MP3 delivered via WCSession `transferFile`)
/// through the watch speaker. The Volume drawer keeps the MEDIA volume route
/// active for the Digital Crown WITHOUT interrupting a reply that's already
/// speaking, and WITHOUT any audible tone.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate, ObservableObject {
    static let shared = AudioPlayer()
    /// True while a reply clip (or queued chunks) is playing — drives the watch
    /// UI into the "speaking" screen the moment audio starts, instead of waiting
    /// for the final reply text. Not set by the silent volume-calibration loop.
    @Published var isSpeaking = false
    /// 0…1 playback position of the current reply clip — drives the watch's
    /// karaoke word highlight. Reset to 0 when a clip starts, set to 1 when it
    /// finishes.
    @Published var playbackProgress: Double = 0
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?  // polls the clip position for the highlight
    private var calibrating = false   // true only while the silent volume loop owns `player`
    private var clipQueue: [Data] = []  // pending reply-clip chunks, played in order
    private var volumeDrawerOpen = false // Volume drawer visible → keep the media route for the Crown
    /// plan 1.6/2 — clips can arrive over TWO different channels
    /// (`sendMessageData`, delivered immediately, vs. queued `transferFile`
    /// for bigger clips), so arrival order is not reading order: a later,
    /// small clip can reach the watch before an earlier, large one that's
    /// still being transferred. `enqueueClip(_:seq:)` buffers out-of-order
    /// clips here and only hands them to the play queue once every earlier
    /// `seq` has been seen.
    private var nextSeqToPlay = 0
    private var pendingBySeq: [Int: Data] = [:]

    func play(base64 string: String) {
        guard let data = Data(base64Encoded: string), !data.isEmpty else {
            VoiceStatus.shared.set("🔇 bad clip data"); return
        }
        play(data: data)
    }

    func play(data: Data) {
        calibrating = false           // a real reply clip takes over the player
        clipQueue.removeAll()
        isSpeaking = true
        start(data: data, loop: false)
    }

    /// Enqueue one reply-clip chunk, identified by its `seq` in the turn
    /// (plan 1.6/2). Held back if an earlier-numbered clip hasn't arrived
    /// yet — sent to the play queue strictly in `seq` order, regardless of
    /// which transport channel it actually arrived over.
    func enqueueClip(_ data: Data, seq: Int) {
        isSpeaking = true
        pendingBySeq[seq] = data
        drainReadyClips()
    }

    /// Hand every contiguous, already-arrived clip starting at
    /// `nextSeqToPlay` to the play queue, in order.
    private func drainReadyClips() {
        while let data = pendingBySeq.removeValue(forKey: nextSeqToPlay) {
            nextSeqToPlay += 1
            if let p = player, p.isPlaying, !calibrating {
                clipQueue.append(data)            // a chunk is already playing → queue after it
            } else {
                calibrating = false               // preempt the silent volume loop / idle
                start(data: data, loop: false)
            }
        }
    }

    /// Clear queued + playing reply clips (called when a new ask begins) so a
    /// previous reply's audio can't bleed into the new one. Leaves the silent
    /// volume-calibration loop alone.
    func resetClips() {
        clipQueue.removeAll()
        pendingBySeq.removeAll()
        nextSeqToPlay = 0
        isSpeaking = false
        stopProgressPolling(completed: false)
        playbackProgress = 0
        if let p = player, p.isPlaying, !calibrating {
            p.stop()
            player = nil
        }
    }

    // MARK: - Karaoke playback-position polling
    private func startProgressPolling() {
        progressTimer?.invalidate()
        playbackProgress = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.isPlaying, !self.calibrating,
                      p.duration > 0 else { return }
                self.playbackProgress = min(1.0, p.currentTime / p.duration)
            }
        }
    }

    private func stopProgressPolling(completed: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        if completed { playbackProgress = 1.0 }  // light up the whole reply
    }

    /// Stop the reply immediately — clears the queue + stops the current clip,
    /// so the watch's "Stop" button can interrupt a long spoken reply. Leaves
    /// the silent volume-calibration loop alone.
    func stopSpeaking() {
        resetClips()
    }

    /// Keep the MEDIA volume route active while the Volume drawer is open so the
    /// Digital Crown adjusts media (not ring) volume.
    /// - If a reply clip is already playing, IT is the active media — leave it
    ///   alone (no interruption, no tone).
    /// - Otherwise loop a SILENT buffer so the crown still has media to grab,
    ///   with no audible beep.
    func beginVolumeCalibration() {
        volumeDrawerOpen = true
        if let p = player, p.isPlaying, !calibrating { return }   // don't interrupt the reply
        calibrating = true
        start(data: AudioPlayer.makeSilentLoop(), loop: true)
    }
    func endVolumeCalibration() {
        volumeDrawerOpen = false
        // Stop the silent calibration loop if it's what's playing — NEVER the reply.
        if calibrating {
            calibrating = false
            player?.stop()
            player = nil
        }
        // Drawer closed and nothing is speaking → release the audio session so the
        // watch audio route doesn't stay powered. (A reply still playing keeps the
        // session; it deactivates on finish, since the drawer is now closed.)
        if player == nil { deactivateSession() }
    }

    /// Best-effort release of the shared audio session so the watch audio route
    /// isn't held powered after playback. A failure just leaves it as-is.
    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        } catch {}
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
                    if !loop { self.startProgressPolling() }
                    VoiceStatus.shared.set("")   // clean on success
                } catch {
                    VoiceStatus.shared.set("🔇 \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            // Chain to the next queued reply-clip chunk, if any.
            if !self.clipQueue.isEmpty {
                let next = self.clipQueue.removeFirst()
                self.start(data: next, loop: false)  // restarts polling for the next chunk
            } else {
                self.isSpeaking = false   // queue drained → speaking finished
                self.stopProgressPolling(completed: true)
                if self.volumeDrawerOpen {
                    // Drawer still open → keep the Crown's media route alive with
                    // the silent loop instead of releasing the session.
                    self.calibrating = true
                    self.start(data: AudioPlayer.makeSilentLoop(), loop: true)
                } else {
                    self.deactivateSession()
                }
            }
        }
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
