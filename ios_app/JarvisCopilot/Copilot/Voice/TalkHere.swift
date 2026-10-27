import Foundation

/// The voice session as a "Talk to JARVIS here" press sees it.
@MainActor
protocol TalkHereVoice: AnyObject {
    var isActive: Bool { get }
    func startOneShotTurn(inBackground: Bool) async -> Bool
    func waitUntilCapturing(timeout: TimeInterval) async -> Bool
    func stopTalk() async
}

extension VoiceStore: TalkHereVoice {
    func stopTalk() async { await stopAll() }
}

/// One press of "Talk to JARVIS here" (the Action button), app side: a running
/// talk stops; otherwise a Siri-style one — one question, one answer, the one-shot
/// turn — starts with Jarvis in the background and the island popped open on it.
///
/// It returns only once the mic is really capturing: iOS lets a backgrounded app
/// start recording only while the intent is still running. Anything short of that
/// is `.needsApp`, and the intent opens Jarvis listening instead.
@MainActor
final class TalkHere {
    /// How long the mic gets to come up (audio session, engine, first frame).
    static let micTimeout: TimeInterval = 4

    private let voice: TalkHereVoice
    private let isForeground: () -> Bool
    private let island: LiveActivityCoordinating
    private let log: (String) -> Void
    /// Keeps Jarvis's background audio session recordable from now on (the
    /// record-ready keepalive): the first press arms it.
    private let arm: () -> Void

    init(voice: TalkHereVoice, isForeground: @escaping () -> Bool, island: LiveActivityCoordinating,
         log: @escaping (String) -> Void = { _ in }, arm: @escaping () -> Void = {}) {
        self.voice = voice
        self.isForeground = isForeground
        self.island = island
        self.log = log
        self.arm = arm
    }

    func press() async -> TalkHereBridge.Outcome {
        arm()
        if voice.isActive {
            log("talk here: a talk is running — stopping it")
            await voice.stopTalk()
            return .stopped
        }
        // Jarvis is on screen: its own Voice screen listens, as the old shortcut did.
        if isForeground() {
            log("talk here: Jarvis is on screen — its Voice screen listens")
            return .needsApp
        }
        log("talk here: starting a one-shot turn in the background")
        // The turn's own frames put the Live Activity up (`AudioRecordingIntent` wants
        // one while recording) from its connecting frame on, and the island pops open
        // on its first "Listening…", the moment the mic is live — not before.
        island.presentVoiceTurn()
        guard await voice.startOneShotTurn(inBackground: true) else {
            log("talk here: the one-shot turn didn't start")
            island.reportVoice(Self.frame("idle"))
            return .needsApp
        }
        guard await voice.waitUntilCapturing(timeout: Self.micTimeout) else {
            log("talk here: the mic didn't come up in \(Int(Self.micTimeout)) s")
            await voice.stopTalk()
            // Straight to the card, past the voice throttle, which can drop a repeat
            // "idle" as a duplicate and leave the "listening" above showing.
            island.reportVoice(Self.frame("idle"))
            return .needsApp
        }
        log("talk here: mic live")
        return .listening
    }

    private static func frame(_ state: String) -> VoiceLiveActivitySnapshot {
        VoiceLiveActivitySnapshot(state: state, transcript: "", activity: "", connected: true, devices: [])
    }
}
