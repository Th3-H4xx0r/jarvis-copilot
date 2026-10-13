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

    var onAmplitude: ((Double) -> Void)?

    // MARK: Stream

    private var streamFormat: AVAudioFormat?
    private var streamGeneration = 0
    /// Latched false once the engine refuses to start, so we don't keep retrying
    /// a broken output and `AudioQueue` falls back to WAV clips.
    private(set) var isStreamAvailable = true

    // MARK: Clip

    var onClipComplete: (() -> Void)?
    var onClipPosition: ((TimeInterval) -> Void)?
    var onClipDuration: ((TimeInterval) -> Void)?

    private var clip: AVAudioPlayer?
    private var positionTimer: Timer?
    /// See `AudioOutput.setVolume`. New streams and clips start at it.
    private var volume: Float = 1
    private var meterTimer: Timer?

    // MARK: - Stream path

    func startStream(sampleRate: Int) async -> Bool {
        await stopStream()
        // The reply plays on the conversation engine, beside the mic, so voice
        // processing cancels it — see `VoiceAudioEngine`. The Mac does the same.
        do {
            streamGeneration += 1
            let generation = streamGeneration
            try VoiceAudioEngine.shared.startStream(sampleRate: sampleRate) { [weak self] level in
                guard let self, self.streamGeneration == generation, self.clip == nil else { return }
                self.onAmplitude?(level)
            }
            streamFormat = VoiceAudioEngine.shared.streamFormat
            return streamFormat != nil
        } catch {
            JcLog.report(JcLog.voice, "start render stream", error)
            isStreamAvailable = false
            return false
        }
    }

    func feed(_ pcm: Data) async {
        guard let format = streamFormat, let buffer = Self.floatBuffer(pcm, format: format) else { return }
        VoiceAudioEngine.shared.schedule(buffer)
    }

    /// PCM16 little-endian → a Float32 buffer in `format`.
    nonisolated static func floatBuffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Copy into an aligned array first: `Data`'s bytes aren't guaranteed to
        // be 2-byte aligned, so binding them in place would be undefined.
        var samples = [Int16](repeating: 0, count: frames)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0, count: frames * 2) }
        for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0 }
        return buffer
    }

    var outputLatencyMs: Int {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return Int(((session.outputLatency + session.ioBufferDuration) * 1000).rounded())
        #else
        return Int((VoiceAudioEngine.shared.outputPresentationLatency * 1000).rounded())
        #endif
    }

    func flushStream() async {
        VoiceAudioEngine.shared.flushStream()
    }

    func setVolume(_ volume: Float) {
        let volume = min(max(volume, 0), 1)
        self.volume = volume
        VoiceAudioEngine.shared.replyVolume = volume
        clip?.volume = volume
    }

    func stopStream() async {
        streamGeneration += 1
        if streamFormat != nil { VoiceAudioEngine.shared.stopStream() }
        streamFormat = nil
        onAmplitude?(0)
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
            player.isMeteringEnabled = true
            player.volume = volume
            player.prepareToPlay()
            guard player.play() else { return false }
            clip = player
            // Unlike the Flutter player, the decoded duration is known right
            // away, so the karaoke schedule is right from the first word instead
            // of starting on a words × rate estimate.
            if player.duration > 0 { onClipDuration?(player.duration) }
            startPositionTimer()
            startClipMeter()
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
        meterTimer?.invalidate()
        meterTimer = nil
        positionTimer?.invalidate()
        positionTimer = nil
        if let clip {
            clip.delegate = nil
            clip.stop()
        }
        clip = nil
        onAmplitude?(0)
    }

    private func startClipMeter() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let clip = self.clip, clip.isPlaying else { return }
                clip.updateMeters()
                let peak = (0..<clip.numberOfChannels).map { clip.peakPower(forChannel: $0) }.max() ?? -160
                self.onAmplitude?(Self.linearAmplitude(decibels: Double(peak)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    nonisolated static func linearAmplitude(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max(pow(10, decibels / 20), 0), 1)
    }

    nonisolated static func peakAmplitude(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        if buffer.format.isInterleaved {
            for i in 0..<(frames * count) { peak = max(peak, abs(channels[0][i])) }
        } else {
            for channel in 0..<count {
                for i in 0..<frames { peak = max(peak, abs(channels[channel][i])) }
            }
        }
        return peak.isFinite ? min(Double(peak), 1) : 0
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
