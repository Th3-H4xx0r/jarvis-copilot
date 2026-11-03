import AppKit

/// Notices macOS's own password dialogs (admin rights, Keychain access: both are
/// SecurityAgent windows) and tells jc-client, which asks Pranav on his iPhone or
/// in the menu bar. Window owner names need no Screen Recording permission.
@MainActor
final class SecurityAgentWatch {
    static let shared = SecurityAgentWatch()
    /// Set while Jarvis's own one-time setup shows the admin dialog (he's at the Mac).
    var suppressed = false
    private var timer: Timer?
    private var showing = false

    func start(link: JcLink = .shared) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(link: link) }
        }
    }

    private func tick(link: JcLink) {
        let now = Self.isShowing()
        defer { showing = now }
        guard now, !showing, !suppressed else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let context = app.isEmpty || app == "SecurityAgent" ? "A Mac password dialog" : "Password dialog over \(app)"
        link.request(["type": "password_seen", "kind": "admin", "context": context])
    }

    nonisolated static func isShowing() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "SecurityAgent" }
    }
}
