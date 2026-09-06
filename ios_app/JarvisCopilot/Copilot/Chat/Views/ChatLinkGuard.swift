import SwiftUI

/// What a link inside a chat reply is allowed to do on tap.
///
/// Markdown links in the transcript are *model output* — the agent, or anything
/// that talked it into emitting a link. SwiftUI's default `openURL` hands any
/// scheme straight to the system, so `shortcuts://run-shortcut?name=…`,
/// `App-Prefs:` or a `jarviscopilot://` self-callback fires on one tap with no
/// confirmation (security M5). http/https/mailto behave as normal links;
/// everything else has to be confirmed by the person tapping it.
enum ChatLinkPolicy {

    /// Schemes that open with no questions asked.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        allowedSchemes.contains((url.scheme ?? "").lowercased())
    }

    /// The line the confirmation sheet shows: the scheme is the part that matters,
    /// so it leads, and a long URL is clipped rather than pushed off screen.
    static func confirmation(for url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let shown = url.absoluteString.count > 120
            ? String(url.absoluteString.prefix(120)) + "…"
            : url.absoluteString
        return "This link opens another app (\(scheme.isEmpty ? "unknown scheme" : scheme)):\n\(shown)"
    }
}

/// Applies ``ChatLinkPolicy`` to every link inside the view it wraps.
struct ChatLinkGuardModifier: ViewModifier {
    @State private var pending: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard ChatLinkPolicy.isAllowed(url) else {
                    pending = url
                    return .handled
                }
                return .systemAction
            })
            .confirmationDialog("Open this link?",
                                isPresented: Binding(get: { pending != nil },
                                                     set: { if !$0 { pending = nil } }),
                                presenting: pending) { url in
                Button("Open", role: .destructive) {
                    pending = nil
                    #if canImport(UIKit)
                    UIApplication.shared.open(url)
                    #endif
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { url in
                Text(ChatLinkPolicy.confirmation(for: url))
            }
    }
}

extension View {
    /// Gate the links inside a chat transcript. See ``ChatLinkPolicy``.
    func chatLinkGuard() -> some View { modifier(ChatLinkGuardModifier()) }
}
