import AppKit
import ApplicationServices

/// What the grab can read from the app in front. The real one asks the browser or Finder over
/// Apple Events and the app over Accessibility; tests pass a fake.
protocol HoloFrontProbe {
    func browserPage(bundleID: String) async -> (url: String, title: String)?
    func finderSelection() async -> [String]
    func documentPath(pid: pid_t) -> String?
    func selectedText(pid: pid_t) -> String?
}

/// "Grab what's in front" (the Holo Drop shortcut, menu, notch button, flick): the browser's
/// page, else Finder's selected files, else the front document, else the selected text, else
/// nothing (the popup then asks to paste or drop a file). Only read on that press.
enum HoloGrab {
    /// Browsers whose page address Apple Events can read; Safari names it differently.
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                                        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
                                        "com.google.Chrome.canary", "com.apple.SafariTechnologyPreview"]
    static let finder = "com.apple.finder"

    static func grab(bundleID: String?, pid: pid_t, probe: HoloFrontProbe,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> HoloItem? {
        if let id = bundleID, browsers.contains(id), let page = await probe.browserPage(bundleID: id),
           let u = URL(string: page.url.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return .link(u, title: page.title.isEmpty ? nil : page.title)
        }
        if bundleID == finder {
            let paths = await probe.finderSelection()
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && exists($0) }
            if !paths.isEmpty { return .files(paths.map { URL(fileURLWithPath: $0) }) }
        }
        if let doc = probe.documentPath(pid: pid), let item = documentItem(doc, exists: exists) { return item }
        if let text = probe.selectedText(pid: pid), let item = HoloItem.fromText(text) { return item }
        return nil
    }

    /// AXDocument is a file URL ("file:///Users/…"), a plain path, or — in some browsers — the
    /// page's address.
    static func documentItem(_ raw: String, exists: (String) -> Bool) -> HoloItem? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), let scheme = u.scheme?.lowercased() {
            if scheme == "file" { return exists(u.path) ? .files([u]) : nil }
            if scheme == "http" || scheme == "https", u.host != nil { return .link(u, title: nil) }
            return nil
        }
        if t.hasPrefix("/"), exists(t) { return .files([URL(fileURLWithPath: t)]) }
        return nil
    }

    static func browserScript(_ bundleID: String) -> String {
        let tab = bundleID.hasPrefix("com.apple.Safari") ? "current tab" : "active tab"
        let title = bundleID.hasPrefix("com.apple.Safari") ? "name" : "title"
        return """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            return (URL of \(tab) of front window) & linefeed & (\(title) of \(tab) of front window)
        end tell
        """
    }

    static let finderScript = """
    tell application id "com.apple.finder"
        set out to ""
        repeat with f in (get selection as alias list)
            set out to out & POSIX path of f & linefeed
        end repeat
        return out
    end tell
    """
}

/// The real probe: Apple Events (Automation) for browsers and Finder, Accessibility for the
/// document and the selection.
struct HoloSystemProbe: HoloFrontProbe {
    func browserPage(bundleID: String) async -> (url: String, title: String)? {
        guard let out = await Scripts.run(HoloGrab.browserScript(bundleID)).output, !out.isEmpty else { return nil }
        let lines = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (lines.first ?? "", lines.count > 1 ? lines[1] : "")
    }

    func finderSelection() async -> [String] {
        (await Scripts.run(HoloGrab.finderScript).output ?? "").split(separator: "\n").map(String.init)
    }

    func documentPath(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    func selectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &v) == .success,
              let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
