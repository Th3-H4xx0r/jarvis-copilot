import AVFoundation
import Observation

/// "Test speakers": one spoken line through whatever output iOS has chosen — the
/// glasses when they are on the route — so pairing can be checked by ear.
@Observable
@MainActor
final class GlassesSpeakerTest: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false
    private(set) var error: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Whether the line started on the glasses, which is what ticks "Hear Jarvis".
    @ObservationIgnored private var onGlasses = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play() {
        guard !speaking else { return }
        error = nil
        do {
            // Through the arbiter, like the Pod's clip player: setting the category
            // here directly is refused while Voice, Live or the keepalive hold it.
            try AudioSessionArbiter.shared.hold(.playback)
        } catch {
            self.error = "The phone's audio would not start: \(error.localizedDescription)"
            return
        }
        onGlasses = GlassesAudioLink.shared.state.speakers
        let line = AVSpeechUtterance(string: "This is Jarvis, speaking through your glasses.")
        line.voice = AVSpeechSynthesisVoice(language: "en-GB")
        speaking = true
        synthesizer.speak(line)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish(completed: Bool) {
        speaking = false
        try? AudioSessionArbiter.shared.release(.playback)
        if completed && onGlasses { GlassesAudioLink.shared.noteHeardSpeakers() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(completed: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish(completed: false) }
    }
}
