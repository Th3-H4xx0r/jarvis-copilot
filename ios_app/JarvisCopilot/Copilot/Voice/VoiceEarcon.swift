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
    /// Plays the sound; returns how many ms of mic audio will still carry it.
    @discardableResult func play(_ earcon: VoiceEarcon) -> Int
}

/// Plays the earcons as generated tones through the voice audio session, so they
/// reach the car's speakers wherever the reply does (and ignore the silent switch).
/// Each is one soft glide, like Siri's and Gemini's (his ask, 2026-10-18: "less
/// annoying … more professional"): a quick lift for "go ahead", a gentle fall for
/// "got it" — no separate notes, no edges.
final class ToneEarconPlayer: EarconPlaying {
    /// One sound: the pitch slides `from` → `to` over `glideMs`, then rings out; `ms` long in all.
    struct Glide: Equatable {
        let from: Double
        let to: Double
        let glideMs: Int
        let ms: Int
    }

    private var players: [VoiceEarcon: AVAudioPlayer] = [:]

    /// Past the sound's end, room for the car's cabin to stop ringing with it.
    static let echoTailMs = 100

    /// D5 rising to A5 for listening; A5 settling to E5 when he's done.
    static func sound(_ earcon: VoiceEarcon) -> Glide {
        switch earcon {
        case .listening: return Glide(from: 587.33, to: 880.00, glideMs: 150, ms: 240)
        case .thinking: return Glide(from: 880.00, to: 659.25, glideMs: 140, ms: 220)
        }
    }

    @discardableResult
    func play(_ earcon: VoiceEarcon) -> Int {
        if players[earcon] == nil {
            let volume = earcon == .listening ? 0.15 : 0.12
            players[earcon] = try? AVAudioPlayer(data: Self.wav(Self.sound(earcon), volume: volume),
                                                 fileTypeHint: AVFileType.wav.rawValue)
            players[earcon]?.prepareToPlay()
        }
        guard let player = players[earcon] else { return 0 }
        player.currentTime = 0
        player.play()
        // The mic hears the sound until it has left the speaker — its length plus
        // the route's output delay (wireless CarPlay adds a lot) — and the frames
        // carrying it arrive later still, by the input delay and one buffer.
        var heard = player.duration
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        heard += session.outputLatency + session.inputLatency + session.ioBufferDuration
        #endif
        return Int((heard * 1000).rounded()) + Self.echoTailMs
    }

    /// 16-bit mono PCM WAV of one glide. The pitch moves on a musical (exponential)
    /// curve that eases out, so it lands rather than slides; a second voice a hair
    /// sharp gives it a soft shimmer and a quiet octave some warmth. A smooth fade in,
    /// an easy decay, and a fade to true silence at the end: nothing that clicks.
    static func wav(_ glide: Glide, volume: Double = 0.15, rate: Int = 24000) -> Data {
        let count = rate * glide.ms / 1000
        let glideCount = max(1, Double(rate * glide.glideMs / 1000))
        let attack = Double(rate) * 0.018
        let fade = Double(rate) * 0.04
        let decay = Double(count) / 2.2
        var samples: [Int16] = []
        samples.reserveCapacity(count)
        var phase = 0.0, shimmer = 0.0
        for i in 0..<count {
            let t = Double(i)
            let x = min(1, t / glideCount)
            let eased = 1 - pow(1 - x, 3)
            let hz = glide.from * pow(glide.to / glide.from, eased)
            phase += 2 * .pi * hz / Double(rate)
            shimmer += 2 * .pi * hz * 1.004 / Double(rate)
            let rise = 0.5 - 0.5 * cos(.pi * min(1, t / attack))
            let fall = 0.5 - 0.5 * cos(.pi * min(1, Double(count - 1 - i) / fade))
            let envelope = rise * exp(-t / decay) * fall
            let value = (sin(phase) + 0.35 * sin(shimmer) + 0.08 * sin(2 * phase)) / 1.43 * volume * envelope
            samples.append(Int16(value * Double(Int16.max)))
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
