#if os(iOS)
import AppIntents
import Foundation

/// "Open Voice and start a turn", as an App Intent.
///
/// Compiled into BOTH the app and the `JarvisWidget` extension: the extension
/// needs the type so the Control Center control can reference it, and the app
/// needs it because `openAppWhenRun` makes iOS run `perform()` IN THE APP'S
/// process when the control is tapped. Running in-app is what lets it set the
/// same `jc_pending_voice` flag and post the same `jcStartVoice` notification
/// that Siri's `StartVoiceIntent` uses.
///
/// Deliberately NOT an `OpenURLIntent`: opening a custom scheme from a Control
/// Center control proved unreliable in the Flutter build, and mirroring the
/// proven Siri path is robust.
@available(iOS 16.0, *)
struct OpenJarvisVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to JARVIS"
    static let description = IntentDescription("Open JARVIS and start listening.")
    static let openAppWhenRun = true
    /// Kept out of Shortcuts/Spotlight — the app exposes a discoverable
    /// `StartVoiceIntent` for that.
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: JarvisShared.pendingVoiceKey)
        NotificationCenter.default.post(
            name: Notification.Name(JarvisShared.startVoiceNotification), object: nil)
        return .result()
    }
}
#endif
