import Foundation

/// The CarPlay Talk widget, app side: runs its button.
///
/// The widget itself doesn't follow the turn — WidgetKit redraws a widget of a
/// backgrounded app on its own schedule, merging or dropping updates, so a live
/// "Listening… / Thinking…" there froze on whatever it last drew. It redraws
/// reliably right after its button runs, so it shows one thing: whether that tap
/// worked. The turn itself is on the Live Activity card and in the earcons.
@MainActor
final class CarTalkFeed {
    static let shared = CarTalkFeed()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = CarTalkSnapshot.store) {
        self.defaults = defaults
    }

    /// The button: a running turn stops; otherwise a one-shot turn starts — the
    /// Live Activity first (`AudioRecordingIntent` wants one up while recording),
    /// and this returns only once the mic is live, because iOS lets a backgrounded
    /// app start recording only while the intent is still running.
    func toggle(voice: VoiceStore, report: (VoiceLiveActivitySnapshot) -> Void) async {
        switch CarTalkBridge.action(sessionActive: voice.isActive) {
        case .stop:
            await voice.stopAll()
            noteTap(failure: nil)
        case .start:
            report(VoiceLiveActivitySnapshot(state: "listening", transcript: "", activity: "",
                                             connected: true, devices: []))
            if await voice.startOneShotTurn() {
                await voice.waitUntilLive()
                noteTap(failure: voice.state == .error ? (voice.error ?? "Couldn't start") : nil)
            } else {
                // Refused (mic permission, iOS): straight to the card, past the voice
                // throttle, which would drop a repeat of the same error as a duplicate
                // and leave the "listening" above showing with the mic off.
                let why = voice.error ?? "Allow the microphone on your iPhone"
                report(VoiceLiveActivitySnapshot(state: "idle", transcript: "", activity: why,
                                                 connected: true, devices: []))
                noteTap(failure: why)
            }
        }
    }

    /// What the widget shows after this tap: nothing, or why it didn't start.
    private func noteTap(failure: String?) {
        CarTalkSnapshot(state: failure == nil ? "idle" : "error", line: failure ?? "",
                        updatedAt: Date()).save(defaults)
    }
}
