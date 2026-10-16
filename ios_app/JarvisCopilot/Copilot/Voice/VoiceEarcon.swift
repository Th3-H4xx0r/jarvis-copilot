import AVFoundation
import Foundation

/// The two short sounds of a car turn: the mic is listening, and it stopped
/// listening and is thinking. Eyes on the road — this is how he knows.
enum VoiceEarcon: Equatable {
    case listening, thinking

    /// Any way into listening (the turn opened, a reply ended); listening ending
    /// because he finished talking. Stop and errors make no sound.
    static func forTransition(from before: VoiceState, to after: VoiceState) -> VoiceEarcon? {
        if after == .listening, before != .listening { return .listening }
        if before == .listening, after == .thinking { return .thinking }
        return nil
    }
}

protocol EarconPlaying: AnyObject {
    func play(_ earcon: VoiceEarcon)
}

/// Plays the earcons as generated tones through the voice audio session, so they
/// reach the car's speakers wherever the reply does (and ignore the silent switch).
/// Soft, low, bell-like notes — a gentle rising fifth for "go ahead", the same
/// fifth falling for "got it" — rather than beeps.
final class ToneEarconPlayer: EarconPlaying {
    private var players: [VoiceEarcon: AVAudioPlayer] = [:]

    func play(_ earcon: VoiceEarcon) {
        if players[earcon] == nil {
            // C5 → G5 rising; G5 → C5 falling.
            let tones: [(hz: Double, ms: Int)] = earcon == .listening
                ? [(hz: 523.25, ms: 130), (hz: 783.99, ms: 260)]
                : [(hz: 783.99, ms: 130), (hz: 523.25, ms: 260)]
            players[earcon] = try? AVAudioPlayer(data: Self.wav(tones), fileTypeHint: AVFileType.wav.rawValue)
            players[earcon]?.prepareToPlay()
        }
        guard let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }

    /// 16-bit mono PCM WAV of the notes back to back. Each is a soft bell: a quick
    /// 12 ms attack, an exponential decay (no hard edge, nothing sharp), a touch of
    /// the octave for warmth, and a short fade so it never clicks.
    static func wav(_ tones: [(hz: Double, ms: Int)], volume: Double = 0.2, rate: Int = 24000) -> Data {
        var samples: [Int16] = []
        for tone in tones {
            let count = rate * tone.ms / 1000
            let attack = Double(rate) * 0.012
            let tail = max(1, rate * 10 / 1000)
            let decay = Double(count) / 3.5
            for i in 0..<count {
                let t = Double(i)
                let envelope = min(1, t / attack) * exp(-t / decay) * min(1, Double(count - 1 - i) / Double(tail))
                let phase = 2 * .pi * tone.hz * t / Double(rate)
                let value = (sin(phase) + 0.18 * sin(2 * phase)) / 1.18 * volume * envelope
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for sample in samples { put(sample) }
        return data
    }
}
