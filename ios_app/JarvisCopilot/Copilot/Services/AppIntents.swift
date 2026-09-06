import Foundation
#if os(iOS)
import AppIntents
import UIKit
#endif

/// A prompt handed to the app from outside — Siri, Shortcuts, or the home-screen
/// quick action — to be sent as a chat turn.
///
/// A latch for the same reason `AppRouter.voiceLaunchRequested` is one: on a cold
/// launch the intent runs before any page exists to hear it, so the request has
/// to survive until Chat mounts and consumes it.
///
/// `send` is the escape hatch for whoever owns the Chat screen: register a sender
/// and the prompt is dispatched immediately instead of waiting to be consumed.
/// `AppServices` installs a default sender that goes straight to the server, so
/// "Ask JARVIS, when is my flight" answers even if the user never opens Chat.
@MainActor
@Observable
final class ChatLaunchBus {
    static let shared = ChatLaunchBus()

    private(set) var pendingPrompt: String?
    /// Bumped on every request, so a view can `.onChange` even when the same
    /// prompt arrives twice.
    private(set) var generation = 0

    /// Installed by `AppServices`; the Chat screen may replace it with one that
    /// renders the turn in the open thread.
    @ObservationIgnored var send: ((String) async -> Void)?

    init() {}

    func request(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingPrompt = trimmed
        generation += 1
        AppRouter.shared.selectedTab = .chat
        if let send {
            Task { await send(trimmed) }
            pendingPrompt = nil
        }
    }

    @discardableResult
    func consume() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }
}

#if os(iOS)

/// "Start JARVIS voice" — the discoverable Siri / Shortcuts entry point.
///
/// Siri needs the app name in the phrase, so the trigger is e.g. "Hey Siri, start
/// JarvisCopilot voice"; a true custom "Hey JARVIS" wake word is not available
/// to third-party apps (the in-app `WakeService` covers the foreground case).
@available(iOS 16.0, *)
struct StartVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Start JARVIS voice"
    static let description = IntentDescription("Open JARVIS and start a voice conversation.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: JarvisShared.pendingVoiceKey)
        NotificationCenter.default.post(
            name: Notification.Name(JarvisShared.startVoiceNotification), object: nil)
        return .result()
    }
}

/// "Ask JARVIS <something>" — one-shot chat from Siri or Shortcuts.
@available(iOS 16.0, *)
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask JARVIS"
    static let description = IntentDescription("Send a message to JARVIS and open the chat.")
    /// Opening the app is what lets the reply stream in front of the user; a
    /// background answer would have nowhere to go (Siri can't render the tool
    /// calls a JARVIS turn produces).
    static let openAppWhenRun = true

    @Parameter(title: "Message", requestValueDialog: "What should I ask JARVIS?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask JARVIS \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ChatLaunchBus.shared.request(text)
        return .result()
    }
}

/// The app's Siri phrases. On iOS 16+ these also populate the home-screen
/// long-press menu, which is why there is no separate static
/// `UIApplicationShortcutItems` list — one definition, two surfaces.
@available(iOS 16.0, *)
struct JarvisAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Avoid "Talk to …" / "Call …" / "Hey …": Siri routes those to
        // telephony and would dial a contact instead of running the intent.
        AppShortcut(
            intent: StartVoiceIntent(),
            phrases: [
                "Start \(.applicationName) voice",
                "Open \(.applicationName) voice",
                "\(.applicationName) voice",
            ],
            shortTitle: "Start voice",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) something",
            ],
            shortTitle: "Ask JARVIS",
            systemImageName: "bubble.left.fill")
    }
}

#endif

/// The home-screen long-press actions.
///
/// App Shortcuts (above) cover this on iOS 16+, but a dynamic
/// `UIApplicationShortcutItem` still shows for users who have Siri suggestions
/// off, and it is what a pre-App-Intents shortcut would deliver. The type strings
/// are parsed here so the routing is testable.
enum QuickAction: String, CaseIterable, Sendable {
    case voice = "com.jarviscopilot.jarviscopilotMobileAndIOS.quick.voice"
    case chat = "com.jarviscopilot.jarviscopilotMobileAndIOS.quick.chat"
    case coding = "com.jarviscopilot.jarviscopilotMobileAndIOS.quick.coding"

    var title: String {
        switch self {
        case .voice:  return "Talk to JARVIS"
        case .chat:   return "New chat"
        case .coding: return "Coding sessions"
        }
    }

    var symbol: String {
        switch self {
        case .voice:  return "mic.fill"
        case .chat:   return "bubble.left.fill"
        case .coding: return "terminal.fill"
        }
    }

    /// The deep link the action is equivalent to, so both entry points route
    /// through exactly one place.
    var link: AppDeepLink {
        switch self {
        case .voice:  return .voice
        case .chat:   return .chat(session: nil)
        case .coding: return .coding(session: nil)
        }
    }

    static func parse(type: String) -> QuickAction? { QuickAction(rawValue: type) }
}

#if os(iOS)
extension QuickAction {
    static func install(on application: UIApplication = .shared) {
        application.shortcutItems = allCases.map {
            UIApplicationShortcutItem(type: $0.rawValue, localizedTitle: $0.title,
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: $0.symbol))
        }
    }
}
#endif
