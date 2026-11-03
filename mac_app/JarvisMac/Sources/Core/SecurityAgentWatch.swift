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

    nonisolated static let bundleID = "com.apple.SecurityAgent"

    private func tick(link: JcLink) {
        let now = Self.isShowing()
        defer { showing = now }
        guard now, !showing, !suppressed else { return }
        // What the dialog itself says (who asks, for what); the app in front can be anyone.
        let text = Self.dialogText()
        if Self.isAboutJarvis(text) { return }   // something is after Jarvis's own saved password
        let context = text.isEmpty ? "A Mac password dialog (Jarvis couldn't read what it's for)" : text
        link.request(["type": "password_seen", "kind": "admin", "context": String(context.prefix(1500))])
    }

    nonisolated static func isAboutJarvis(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("jarviscopilot") || t.contains(MacPassword.service) || t.contains(ApprovalKey.service)
    }

    /// The dialog's static text through Accessibility (its password field stays hidden).
    nonisolated static func dialogText() -> String {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return "" }
        var texts: [String] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 10, texts.count < 30 else { return }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == (kAXStaticTextRole as String) {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
                if let s = value as? String, !s.isEmpty { texts.append(s) }
            }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
            for kid in (kids as? [AXUIElement]) ?? [] { walk(kid, depth + 1) }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        return texts.joined(separator: " ")
    }

    nonisolated static func isShowing() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "SecurityAgent" }
    }
}
