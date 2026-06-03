import AppIntents
import Foundation

/// "Open Voice + start a turn" App Intent used by the Control Center control.
///
/// This is a member of BOTH the Runner app target AND the JarvisWidget
/// extension target. The extension needs the type so the control can reference
/// it; the app needs it so that — because `openAppWhenRun` is true — iOS runs
/// `perform()` IN THE APP'S process when the control is tapped. Running in-app
/// lets it set the same `jc_pending_voice` flag + post the same `jcStartVoice`
/// notification that AppDelegate.StartVoiceIntent (Siri) uses, which routes to
/// "open the Voice tab and start a realtime turn". Dart's startup pull
/// (`consumePendingVoice`) also picks up the flag on a cold launch.
///
/// We deliberately do NOT use `OpenURLIntent` here — opening a custom URL scheme
/// from a Control Center control proved unreliable; mirroring the proven Siri
/// path is robust.
@available(iOS 16.0, *)
struct OpenJarvisVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to JARVIS"
    static let description = IntentDescription("Open JARVIS and start listening.")
    static let openAppWhenRun = true
    // Keep it out of Shortcuts/Spotlight (the app already exposes a discoverable
    // StartVoiceIntent for Siri/Shortcuts).
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "jc_pending_voice")
        NotificationCenter.default.post(name: Notification.Name("jcStartVoice"), object: nil)
        return .result()
    }
}
