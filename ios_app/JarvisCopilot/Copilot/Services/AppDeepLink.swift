import Foundation

/// Every `jarviscopilot://…` URL the app answers to.
///
/// The Flutter client split this between `AppDelegate.handleIncomingURL` (native)
/// and the pair channel (Dart); here it is one pure parser so the routing table
/// is testable without a scene. Unknown hosts return nil so `.onOpenURL` can fall
/// through to the Shortcuts result bus (which owns `shortcut-result` /
/// `shortcut-error`) and to whatever handles pairing.
enum AppDeepLink: Equatable, Sendable {
    /// `jarviscopilot://voice` — the Lock Screen widget, the Control Center
    /// control and the Live Activity all land here.
    case voice
    /// `jarviscopilot://chat[?session=<id>]`
    case chat(session: String?)
    /// `jarviscopilot://coding[?session=<id>]`
    case coding(session: String?)
    /// `jarviscopilot://island` — a custom-design Live Activity tap. Bring the
    /// app forward and show the designs screen; it must NOT fall through to the
    /// pairing handler (which is what the Flutter comment warns about).
    case island
    /// `jarviscopilot://shortcut-result/<rid>` and `…/shortcut-error/<rid>`.
    /// Parsed here only so a caller can *recognise* one; `ShortcutResultBus` owns
    /// the payload.
    case shortcutCallback
    /// Anything else on our scheme: the pairing deep link
    /// (`jarviscopilot://pair?server=…&code=…`).
    case pair(URL)

    /// Nil when the URL is not ours (a different scheme, or no host at all).
    static func parse(_ url: URL) -> AppDeepLink? {
        guard url.scheme?.lowercased() == JarvisShared.urlScheme else { return nil }
        // `URL.host` is nil for `scheme:///path`; treat that as malformed rather
        // than routing it somewhere arbitrary.
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        switch host {
        case "voice":
            return .voice
        case "chat":
            return .chat(session: query(url, "session"))
        case "coding":
            return .coding(session: query(url, "session"))
        case "island", "designs":
            return .island
        case "shortcut-result", "shortcut-error":
            return .shortcutCallback
        default:
            return .pair(url)
        }
    }

    /// A non-empty query value, or nil. An explicit empty `?session=` means "no
    /// session" — opening a blank thread beats opening one called "".
    private static func query(_ url: URL, _ name: String) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = items.first { $0.name == name }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}

/// The session id a deep link asked to open, latched until the tab that owns it
/// mounts and consumes it.
///
/// A latch, not an event, for the same reason `AppRouter.voiceLaunchRequested` is
/// one: on a cold launch the URL arrives before any page exists to hear it.
@MainActor
@Observable
final class DeepLinkTargets {
    static let shared = DeepLinkTargets()

    private(set) var chatSession: String?
    private(set) var codingSession: String?
    /// Bumped on every request so a view can `.onChange` even when the same id
    /// arrives twice.
    private(set) var generation = 0

    init() {}

    func requestChat(session: String?) {
        chatSession = session
        generation += 1
    }

    func requestCoding(session: String?) {
        codingSession = session
        generation += 1
    }

    @discardableResult
    func consumeChat() -> String? {
        defer { chatSession = nil }
        return chatSession
    }

    @discardableResult
    func consumeCoding() -> String? {
        defer { codingSession = nil }
        return codingSession
    }
}

/// Applies a parsed link to the app's navigation state. Split from the parser so
/// the routing decision can be asserted without a router.
@MainActor
struct AppDeepLinkRouter {
    let router: AppRouter
    let targets: DeepLinkTargets

    init(router: AppRouter = .shared, targets: DeepLinkTargets = .shared) {
        self.router = router
        self.targets = targets
    }

    /// Returns true when the link was handled here. `pair` and `shortcutCallback`
    /// are someone else's, so they come back false and the caller falls through.
    @discardableResult
    func open(_ link: AppDeepLink) -> Bool {
        switch link {
        case .voice:
            router.requestVoiceLaunch()
            return true
        case .chat(let session):
            router.selectedTab = .chat
            targets.requestChat(session: session)
            return true
        case .coding(let session):
            router.selectedTab = .coding
            targets.requestCoding(session: session)
            return true
        case .island:
            // The designs screen lives behind More; the tab is as far as this
            // router goes (More owns its own destination stack).
            router.selectedTab = .more
            return true
        case .shortcutCallback, .pair:
            return false
        }
    }

    /// Convenience for `.onOpenURL`: parse and route in one call.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let link = AppDeepLink.parse(url) else { return false }
        return open(link)
    }
}
