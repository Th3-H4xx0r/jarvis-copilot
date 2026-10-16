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
final class ToneEarconPlayer: EarconPlaying {
    private var players: [VoiceEarcon: AVAudioPlayer] = [:]

    func play(_ earcon: VoiceEarcon) {
        if players[earcon] == nil {
            // A rising pair for "go ahead", the same pair falling for "got it".
            let tones: [(hz: Double, ms: Int)] = earcon == .listening
                ? [(hz: 660, ms: 70), (hz: 990, ms: 110)]
                : [(hz: 990, ms: 70), (hz: 660, ms: 110)]
            players[earcon] = try? AVAudioPlayer(data: Self.wav(tones), fileTypeHint: AVFileType.wav.rawValue)
            players[earcon]?.prepareToPlay()
        }
        guard let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }

    /// 16-bit mono PCM WAV of the tones back to back, each faded in and out so
    /// it doesn't click.
    static func wav(_ tones: [(hz: Double, ms: Int)], volume: Double = 0.35, rate: Int = 24000) -> Data {
        var samples: [Int16] = []
        for tone in tones {
            let count = rate * tone.ms / 1000
            let fade = max(1, rate * 8 / 1000)
            for i in 0..<count {
                let ramp = min(1, Double(min(i, count - 1 - i)) / Double(fade))
                let value = sin(2 * .pi * tone.hz * Double(i) / Double(rate)) * volume * ramp
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
