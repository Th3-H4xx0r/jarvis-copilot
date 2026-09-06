import AVFoundation
import Foundation

/// Playback: a gapless PCM render stream plus one-shot encoded clips.
/// Adapted from the Flutter app's `ios/Runner/PcmStreamBridge.swift`.
///
/// The stream path feeds every arriving chunk to one `AVAudioPlayerNode`, so
/// chunk seams are inaudible. The previous Flutter approach (a temp WAV file and
/// a fresh `play()` per 160/500 ms slice) paid a player stop/start on every
/// slice, which is the "cuts out every second" stutter heard on the phone.
///
/// Audio session: NOT configured here — `DefaultAudioSessionControlling` owns it
/// for the whole conversation. Two owners reconfiguring one session is where
/// every past volume/route regression came from.
@MainActor
final class DefaultAudioOutput: NSObject, AudioOutput {

    /// Karaoke position cadence for clip playback.
    static let positionIntervalMs = 200

    // MARK: Stream

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var streamFormat: AVAudioFormat?
    /// Latched false once the engine refuses to start, so we don't keep retrying
    /// a broken output and `AudioQueue` falls back to WAV clips.
    private(set) var isStreamAvailable = true

    // MARK: Clip

    var onClipComplete: (() -> Void)?
    var onClipPosition: ((TimeInterval) -> Void)?
    var onClipDuration: ((TimeInterval) -> Void)?

    private var clip: AVAudioPlayer?
    private var positionTimer: Timer?

    // MARK: - Stream path

    func startStream(sampleRate: Int) async -> Bool {
        await stopStream()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false) else {
            isStreamAvailable = false
            return false
        }
        engine.attach(node)
        // The mixer resamples 24 kHz mono to whatever the output runs at.
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            // Gapless playback is off for the rest of the launch after this, so
            // it needs to be visible in a support log.
            JcLog.report(JcLog.voice, "start render stream", error)
            isStreamAvailable = false
            return false
        }
        node.play()
        self.engine = engine
        self.node = node
        self.streamFormat = format
        return true
    }

    func feed(_ pcm: Data) async {
        guard let node, let format = streamFormat, let engine else { return }
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Copy into an aligned array first: `Data`'s bytes aren't guaranteed to
        // be 2-byte aligned, so binding them in place would be undefined.
        var samples = [Int16](repeating: 0, count: frames)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0, count: frames * 2) }
        for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0 }
        if !engine.isRunning {
            // A media-services reset or an interruption stopped us; bring it back.
            do { try engine.start() }
            catch {
                JcLog.dropped(JcLog.voice, "restart render stream after reset", error)
                return
            }
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    func flushStream() async {
        guard let node else { return }
        // `stop()` discards every scheduled buffer; `play()` re-arms for the next feed.
        node.stop()
        node.play()
    }

    func stopStream() async {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        streamFormat = nil
    }

    // MARK: - Clip path

    func play(_ bytes: Data, fileExtension: String) async -> Bool {
        stopClipPlayer()
        do {
            // `AVAudioPlayer` decodes straight from memory. Flutter needed a temp
            // file only because audioplayers' `BytesSource` silently fails to
            // decode on iOS (play() "completes" instantly and you hear nothing).
            let player = try AVAudioPlayer(data: bytes,
                                           fileTypeHint: Self.typeHint(fileExtension))
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { return false }
            clip = player
            // Unlike the Flutter player, the decoded duration is known right
            // away, so the karaoke schedule is right from the first word instead
            // of starting on a words × rate estimate.
            if player.duration > 0 { onClipDuration?(player.duration) }
            startPositionTimer()
            return true
        } catch {
            // The queue skips a clip it can't play; without this a corrupt MP3
            // is indistinguishable from a silent one.
            JcLog.report(JcLog.voice, "play clip", error)
            return false
        }
    }

    func stopClip() async { stopClipPlayer() }

    private func stopClipPlayer() {
        positionTimer?.invalidate()
        positionTimer = nil
        if let clip {
            clip.delegate = nil
            clip.stop()
        }
        clip = nil
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(
            withTimeInterval: Double(Self.positionIntervalMs) / 1000, repeats: true
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let clip = self.clip, clip.isPlaying else { return }
                self.onClipPosition?(clip.currentTime)
            }
        }
    }

    private static func typeHint(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav": return AVFileType.wav.rawValue
        case "m4a", "aac": return AVFileType.m4a.rawValue
        case "caf": return AVFileType.caf.rawValue
        default: return AVFileType.mp3.rawValue
        }
    }
}

extension DefaultAudioOutput: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard player === clip else { return }
            stopClipPlayer()
            onClipComplete?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated {
            guard player === clip else { return }
            stopClipPlayer()
            // Treat a bad clip as finished so the queue advances instead of wedging.
            onClipComplete?()
        }
    }
}
