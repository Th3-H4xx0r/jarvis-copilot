import AVFoundation
import Foundation

/// Speaks reply text with the watch's built-in voice. On watchOS,
/// AVSpeechSynthesizer manages its OWN audio session — manually activating a
/// session beforehand actually prevents it from playing — so we just speak.
@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { VoiceStatus.shared.set("🔇 empty reply"); return }
        let u = AVSpeechUtterance(string: t)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        VoiceStatus.shared.set("🗣️ built-in voice")
    }

    /// Stop an in-progress instant ack (plan 1.6c) the moment the hi-fi clip
    /// arrives, so the two voices don't overlap.
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
