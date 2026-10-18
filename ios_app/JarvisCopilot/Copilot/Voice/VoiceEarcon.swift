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

/// Plays the earcons — his chosen chimes (`VoiceEarconSounds`) — through the voice audio
/// session, so they reach the car's speakers wherever the reply does (and ignore the silent
/// switch).
final class ToneEarconPlayer: EarconPlaying {
    private var players: [VoiceEarcon: AVAudioPlayer] = [:]

    /// Past the sound's end, room for the car's cabin to stop ringing with it.
    static let echoTailMs = 100

    @discardableResult
    func play(_ earcon: VoiceEarcon) -> Int {
        if players[earcon] == nil {
            players[earcon] = try? AVAudioPlayer(data: VoiceEarconSounds.data(for: earcon),
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
}
