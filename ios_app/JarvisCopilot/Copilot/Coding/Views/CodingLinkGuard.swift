import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which URL schemes a link in a coding transcript may open unattended.
///
/// The transcript is model + tool output: a `[click here](shortcuts://run?name=…)`
/// in a file Claude just read is attacker-controlled text, and SwiftUI's default
/// `openURL` hands ANY scheme to the system. `shortcuts:` would drive the
/// Shortcuts app around the app's own "run_shortcut" switch, `App-Prefs:` jumps
/// into Settings, and `jarviscopilot:` re-enters our own deep links. So: the
/// three web/mail schemes open directly, everything else asks first.
enum CodingLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func opensDirectly(_ url: URL) -> Bool {
        allowedSchemes.contains((url.scheme ?? "").lowercased())
    }
}

/// Applies `CodingLinkPolicy` to every markdown link below it.
private struct CodingLinkGuard: ViewModifier {
    @State private var pending: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard CodingLinkPolicy.opensDirectly(url) else {
                    pending = url
                    return .handled
                }
                return .systemAction
            })
            .confirmationDialog("Open this link?",
                                isPresented: Binding(get: { pending != nil },
                                                     set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible) {
                if let pending {
                    Button("Open") { Self.openOutsideTheApp(pending) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pending?.absoluteString ?? "")
            }
    }

    /// Deliberately NOT the `openURL` environment action — that's the one we just
    /// replaced, and going through it would loop back into the prompt.
    private static func openOutsideTheApp(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

extension View {
    /// Gate markdown links in coding chat/transcript surfaces behind
    /// `CodingLinkPolicy`.
    func codingSafeLinks() -> some View { modifier(CodingLinkGuard()) }
}
