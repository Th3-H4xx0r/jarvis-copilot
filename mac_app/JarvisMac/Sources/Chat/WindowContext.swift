import AppKit
import ApplicationServices

/// The window you were in when you pressed ⌃⌥W: the app, its focused window's
/// title (Accessibility) and, in a browser, the page's address (Apple Events).
/// Only on that key press; nothing is read otherwise. After coucou's
/// WindowContextCapture (github.com/Louis-CFM/coucou, MIT).
enum WindowContext {
    private static let browserScripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of current tab of front window",
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
    ]

    /// The last regular app that was frontmost before the island took focus.
    @MainActor static var lastApp: NSRunningApplication?

    @MainActor
    static func startWatching() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier, app.activationPolicy == .regular else { return }
            MainActor.assumeIsolated { lastApp = app }
        }
    }

    static func capture(_ app: NSRunningApplication?) -> ChatContext.Window? {
        guard let app, let name = app.localizedName else { return nil }
        var title = ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let win,
           CFGetTypeID(win) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success,
               let s = t as? String {
                title = s
            }
        }
        var url: String?
        if let id = app.bundleIdentifier, let src = browserScripts[id] {
            var err: NSDictionary?
            let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
            if err == nil { url = result?.stringValue }
        }
        return ChatContext.Window(app: name, title: title, url: url)
    }
}
