import AppKit
import ApplicationServices

/// One window of an app, as the iPhone's Dock menu lists it.
struct MacWindowInfo: Equatable {
    /// The window number (CGWindowID), or `MacWindows.fallbackID(index:)` when macOS won't say.
    let id: Int
    let title: String
    let minimized: Bool
    /// The app's main window (the Dock's checkmark).
    let front: Bool
}

/// An app's windows through Accessibility, for the iPhone's Dock menu: "if I have multiple vsc
/// windows, I can't switch it from the iOS app". Lists them (title, id, minimised, frontmost),
/// raises one, and finds the app's own New Window menu item. Accessibility lists only the
/// current Space's windows, so windows on other Spaces and full-screen ones (his second VS Code
/// window, live-checked) are found the way AltTab does: the window server says they exist, and
/// their AX elements are looked up by remote token.
enum MacWindows {
    static let maxWindows = 30
    static let maxTitle = 120

    // MARK: pure (tested)

    /// The phone's `cc_windows` reply. Small on purpose: titles clipped, at most `maxWindows`.
    static func payload(pid: Int, windows: [MacWindowInfo], canNewWindow: Bool, ax: Bool) -> [String: Any] {
        ["t": "cc_windows", "pid": pid, "ax": ax, "new_window": canNewWindow,
         "windows": windows.prefix(maxWindows).map {
             ["id": $0.id, "title": clip($0.title), "min": $0.minimized, "front": $0.front] as [String: Any]
         }]
    }

    static func clip(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= maxTitle ? t : String(t.prefix(maxTitle - 1)) + "…"
    }

    /// A real window: a standard window or dialog, or an untyped one with a title.
    /// Palettes, popovers and the invisible helpers Electron/Chrome keep are left out.
    static func keep(subrole: String?, title: String) -> Bool {
        switch subrole {
        case "AXStandardWindow", "AXDialog": return true
        case nil, "": return !title.trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    static func index(of id: Int, in windows: [MacWindowInfo]) -> Int? {
        windows.firstIndex { $0.id == id }
    }

    /// The id of a window macOS gives no number for: its position, negative so it never
    /// collides with a real window number.
    static func fallbackID(index: Int) -> Int { -(index + 1) }

    /// "New Window", "New Finder Window", "New Private Window"; never "New Window with Profile"
    /// (a submenu) or "New Tab".
    static func isNewWindowTitle(_ title: String) -> Bool {
        let words = title.split(separator: " ")
        guard words.count >= 2, words.count <= 3, words.first == "New", words.last == "Window" else { return false }
        return true
    }

    /// Which of a menu's items to press for New Window: the plain one first.
    static func bestNewWindow(_ titles: [String]) -> Int? {
        titles.firstIndex(of: "New Window") ?? titles.firstIndex { isNewWindowTitle($0) && !$0.contains("Private") }
            ?? titles.firstIndex(where: isNewWindowTitle)
    }

    // MARK: Accessibility

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// `_AXUIElementGetWindow`: the window number behind an AX window (what every window
    /// manager uses), looked up at run time so a missing symbol is only a missing number.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    nonisolated(unsafe) private static let getWindow: GetWindow? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }

    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // A busy app answers late; never hold the queue for long.
        AXUIElementSetMessagingTimeout(app, 1.5)
        return app
    }

    private static func number(_ w: AXUIElement) -> CGWindowID? {
        var n: CGWindowID = 0
        return getWindow?(w, &n) == .success && n != 0 ? n : nil
    }

    /// The app's windows, front to back (then those on other Spaces), with their AX elements.
    static func list(pid: pid_t) -> [(info: MacWindowInfo, element: AXUIElement)] {
        let app = app(pid)
        let main = element(app, kAXMainWindowAttribute) ?? element(app, kAXFocusedWindowAttribute)
        var out: [(info: MacWindowInfo, element: AXUIElement)] = []
        func add(_ w: AXUIElement, fallback: Int) {
            let title = value(w, kAXTitleAttribute) as? String ?? ""
            guard keep(subrole: value(w, kAXSubroleAttribute) as? String, title: title) else { return }
            let id = number(w).map(Int.init) ?? fallbackID(index: fallback)
            guard !out.contains(where: { $0.info.id == id }) else { return }
            let minimized = (value(w, kAXMinimizedAttribute) as? Bool) ?? false
            out.append((MacWindowInfo(id: id, title: title, minimized: minimized,
                                      front: main.map { CFEqual($0, w) } ?? false), w))
        }
        for (i, w) in ((value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).enumerated() {
            add(w, fallback: i)
        }
        let missing = offSpaceWindows(pid: pid).subtracting(out.map { CGWindowID(clamping: $0.info.id) })
        if !missing.isEmpty {
            for w in elements(pid: pid, for: missing) { add(w, fallback: out.count) }
        }
        return out
    }

    /// Window numbers the window server has for the app that look like real windows (normal
    /// layer, not a strip): those Accessibility didn't list are on other Spaces or full screen.
    private static func offSpaceWindows(pid: pid_t) -> Set<CGWindowID> {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out = Set<CGWindowID>()
        for w in all where (w[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard (b["Width"] as? Double ?? 0) >= 100, (b["Height"] as? Double ?? 0) >= 100,
                  let n = w[kCGWindowNumber as String] as? Int else { continue }
            out.insert(CGWindowID(n))
        }
        return out
    }

    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    nonisolated(unsafe) private static let createWithToken: CreateWithToken? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken")
            .map { unsafeBitCast($0, to: CreateWithToken.self) }

    /// AX elements for windows on other Spaces: a remote token is pid + 0 + "coco" + element id
    /// (AltTab's method). Element ids grow with the app's age (his VS Code's windows were ids
    /// ~2000, past AltTab's 1000), so ids are tried until every wanted window is found, within
    /// 0.6 s; a miss costs ~10 µs because only an element inside a wanted window is asked its role.
    private static func elements(pid: pid_t, for wanted: Set<CGWindowID>) -> [AXUIElement] {
        guard let createWithToken else { return [] }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: Int32(pid)) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var left = wanted
        var found: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.6)
        for id: UInt64 in 0..<200_000 {
            if left.isEmpty || (id % 1024 == 0 && Date() > deadline) { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            // Every element inside a window reports that window's number: only the window itself counts.
            guard let el = createWithToken(token as CFData)?.takeRetainedValue(),
                  let n = number(el), left.contains(n),
                  value(el, kAXRoleAttribute) as? String == kAXWindowRole as String else { continue }
            left.remove(n)
            AXUIElementSetMessagingTimeout(el, 1.5)
            found.append(el)
        }
        return found
    }

    /// The app's New Window menu item (in its first few menus: app, File, Shell…), if it has one.
    static func newWindowItem(pid: pid_t) -> AXUIElement? {
        guard let bar = element(app(pid), kAXMenuBarAttribute) else { return nil }
        for top in children(bar).dropFirst().prefix(4) {
            guard let menu = children(top).first else { continue }
            let items = children(menu)
            let titles = items.map { value($0, kAXTitleAttribute) as? String ?? "" }
            if let i = bestNewWindow(titles), (value(items[i], kAXEnabledAttribute) as? Bool) ?? true {
                return items[i]
            }
        }
        return nil
    }

    /// Brings one window to the front: un-minimised, raised, made main, its app activated.
    /// Nil when done, else what went wrong.
    static func raise(pid: pid_t, id: Int) -> String? {
        guard AXIsProcessTrusted() else { return "Allow Jarvis in Accessibility on the Mac to switch windows." }
        let windows = list(pid: pid)
        guard let i = index(of: id, in: windows.map(\.info)) else { return "That window isn't open any more." }
        let w = windows[i].element
        let activated: Bool = DispatchQueue.main.sync {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            app.unhide()
            app.activate(options: [])
            return true
        }
        guard activated else { return "That app isn't running any more." }
        if windows[i].info.minimized {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // A window on another Space (or full screen) only comes forward through the window
        // server: front process for that window, then make it key (AltTab's calls).
        if id > 0 { SkyLight.focus(pid: pid, window: CGWindowID(id)) }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Activating brings the app's last main window forward; raise the picked one after it.
        Thread.sleep(forTimeInterval: 0.12)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        return nil
    }
}

/// The window server's private calls for focusing one window of an app, even on another Space,
/// looked up at run time: a missing symbol only means the plain activate + raise.
private enum SkyLight {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> CGError
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> CGError
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

    nonisolated(unsafe) private static let lib =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated(unsafe) private static let setFront: SetFront? =
        dlsym(lib, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFront.self) }
    nonisolated(unsafe) private static let post: PostEvent? =
        dlsym(lib, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostEvent.self) }
    nonisolated(unsafe) private static let psnForPID: GetPSN? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetPSN.self) }

    static func focus(pid: pid_t, window: CGWindowID) {
        guard let setFront, let post, let psnForPID else { return }
        // ProcessSerialNumber: two UInt32s.
        var psn = [UInt32](repeating: 0, count: 2)
        let ok = psn.withUnsafeMutableBytes { psnForPID(pid, $0.baseAddress!) } == noErr
        guard ok else { return }
        psn.withUnsafeMutableBytes { p in
            _ = setFront(p.baseAddress!, window, 0x200)   // kCPSUserGenerated
            var wid = window
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            withUnsafeBytes(of: &wid) { w in for k in 0..<4 { bytes[0x3c + k] = w[k] } }
            for k in 0..<0x10 { bytes[0x20 + k] = 0xff }
            for phase: UInt8 in [0x01, 0x02] {
                bytes[0x08] = phase
                bytes.withUnsafeMutableBytes { _ = post(p.baseAddress!, $0.baseAddress!) }
            }
        }
    }
}
