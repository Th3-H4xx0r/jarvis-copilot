import Foundation
import WidgetKit

extension CarTalkSnapshot {
    /// The Talk widget's view of a voice turn: its state, and his words or the reply.
    init(_ voice: VoiceLiveActivitySnapshot, at date: Date) {
        self.init(state: voice.state,
                  line: CarCardText.line(state: voice.state, transcript: voice.transcript,
                                         activity: voice.activity),
                  updatedAt: date)
    }
}

/// The CarPlay Talk widget, app side: runs its button and keeps what it shows in
/// step with the voice turn.
@MainActor
final class CarTalkFeed {
    static let shared = CarTalkFeed()
    static let widgetKind = "JarvisCarTalk"

    private var last: CarTalkSnapshot?

    /// The button: a running turn stops; otherwise a one-shot turn starts, the
    /// Live Activity first (`AudioRecordingIntent` wants one up while recording,
    /// and at idle there may be none yet).
    func toggle(voice: VoiceStore, report: (VoiceLiveActivitySnapshot) -> Void) async {
        switch CarTalkBridge.action(sessionActive: voice.isActive) {
        case .stop:
            await voice.stopAll()
        case .start:
            report(VoiceLiveActivitySnapshot(state: "listening", transcript: "", activity: "",
                                             connected: true, devices: []))
            if await voice.startOneShotTurn() == false {
                // Refused (mic permission): put the real state, and why, back on the card.
                voice.pushLiveActivity()
            }
        }
    }

    /// Every voice snapshot passes through. The widget reloads only when its state
    /// changes or a settled line does (his finished words, the reply) — not for
    /// every partial word; the live words are the Live Activity's job.
    func report(_ voice: VoiceLiveActivitySnapshot, now: Date = Date()) {
        let next = CarTalkSnapshot(voice, at: now)
        if let last, last.state == next.state,
           last.line == next.line || next.state == "listening" { return }
        last = next
        next.save()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
}
