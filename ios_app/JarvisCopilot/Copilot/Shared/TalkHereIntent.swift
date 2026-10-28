import AppIntents
import Foundation

/// "Talk to JARVIS here": the Action button (or a Control Center control, or a
/// Shortcut) starts a Siri-style talk right where he is — one question, one answer —
/// with the Dynamic Island showing it, and never opens Jarvis. Pressed again, it stops.
///
/// An `AudioRecordingIntent`, the one way iOS lets an app start the microphone from
/// the background (the Live Activity it requires is the island), and a
/// `LiveActivityIntent` so `perform()` runs in the app's process, where the voice
/// session lives. If iOS still won't start the mic there, Jarvis opens listening
/// instead (his pick, 2026-10-27), as his old "open Jarvis" shortcut did.
///
/// Unlock first: a talk reaches his mail, messages and car, so a locked phone asks
/// for Face ID before it starts.
@available(iOS 18.0, *)
struct TalkToJarvisHereIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Talk to JARVIS here"
    static let description = IntentDescription(
        "Jarvis listens right where you are, like Siri — the Dynamic Island shows it. Run it again to stop.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// Background first; the app comes forward only for the fallback.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        var mode = "-"
        if #available(iOS 26.0, *) { mode = "\(systemContext.currentMode)" }
        // Nil in the widget extension: no microphone there. Nothing happens but a
        // note the app logs on its next launch (a press that never reached the app).
        guard let press = TalkHereBridge.press else {
            TalkHereBridge.noteOutsideApp(mode: mode)
            return .result()
        }
        TalkHereBridge.log?("press (intent mode \(mode))")
        let outcome = await press()
        TalkHereBridge.log?("press → \(outcome)")
        guard outcome == .needsApp else { return .result() }
        if #available(iOS 26.0, *) {
            do {
                try await continueInForeground(nil, alwaysConfirm: false)
            } catch {
                TalkHereBridge.log?("continue in foreground refused: \(error)")
                throw error
            }
        }
        // The same request the "open Jarvis and listen" intent makes.
        UserDefaults.standard.set(true, forKey: JarvisShared.pendingVoiceKey)
        NotificationCenter.default.post(name: Notification.Name(JarvisShared.startVoiceNotification), object: nil)
        return .result()
    }
}

enum TalkHereBridge {
    enum Outcome: Equatable {
        /// The mic is live and the island shows it.
        case listening
        /// A talk was running: it stopped.
        case stopped
        /// It couldn't start here: Jarvis opens listening instead.
        case needsApp
    }

    /// Runs one press. Set by the app at launch; nil in the widget.
    @MainActor static var press: (() async -> Outcome)?
    /// A line in the phone's voice.log. Set by the app.
    @MainActor static var log: ((String) -> Void)?
    /// Ends the talk (the island's ✕). Set by the app; nil in the widget.
    @MainActor static var stop: (() async -> Void)?

    private static let outsideKey = "jc.talkHere.outsideApp"
    private static var shared: UserDefaults { UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard }

    /// A press that ran somewhere without the voice session (the widget extension).
    static func noteOutsideApp(mode: String, at now: Date = Date()) {
        shared.set("\(Bundle.main.bundleIdentifier ?? "?") mode=\(mode) at \(now)", forKey: outsideKey)
    }

    /// The last such press, once (the app logs it at launch).
    static func takeOutsideApp() -> String? {
        let note = shared.string(forKey: outsideKey)
        if note != nil { shared.removeObject(forKey: outsideKey) }
        return note
    }
}

/// The ✕ on the voice island and Lock Screen card: ends the talk — mic off, reply
/// stopped. A Live Activity intent, so it runs in the app, Jarvis staying where it is.
struct StopJarvisVoiceIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop talking to JARVIS"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await TalkHereBridge.stop?()
        TalkHereBridge.log?("stopped from the island")
        return .result()
    }
}
