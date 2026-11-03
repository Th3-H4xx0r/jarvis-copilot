import AppKit
import CoreGraphics
import CoreWLAN
import Foundation

/// The viewer's Command Center over the share's data channel ("input", t = "cc"):
/// the Mac's Control Center switches, its open apps and its displays.
///
///   → {"t":"cc","do":"state"}                     ← cc_state, cc_apps, cc_icon…
///   → {"t":"cc","do":"wifi"|"bluetooth"|"dark"|"mute","on":Bool}
///   → {"t":"cc","do":"volume","value":0…100}      {"do":"brightness","value":0…1}
///   → {"t":"cc","do":"media","key":"play"|"next"|"previous"}
///   → {"t":"cc","do":"app","pid":Int}             {"do":"display","id":UInt32}
///   → {"t":"cc","do":"lock"|"control_center"|"mission_control"|"show_desktop"}
///
/// Every action answers with a fresh `cc_state` (and `cc_apps` when apps change),
/// so the phone's tiles always show what the Mac really is. Runs on its own queue:
/// AppleScript and private-framework calls never hold up the video or the input.
final class MacControls: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jarvis.screen.controls", qos: .userInitiated)
    private weak var pipeline: FramePipeline?
    private let reply: @Sendable ([String: Any]) -> Void
    /// Icons this viewer already has (by bundle id): each goes once. On `queue`.
    private var sentIcons = Set<String>()

    init(pipeline: FramePipeline, reply: @escaping @Sendable ([String: Any]) -> Void) {
        self.pipeline = pipeline
        self.reply = reply
    }

    func handle(_ m: [String: Any]) {
        queue.async { [self] in run(m) }
    }

    // MARK: actions (on `queue`)

    private func run(_ m: [String: Any]) {
        let action = J.s(m["do"])
        let on = J.b(m["on"])
        var problem: String?
        var appsChanged = action == "state"
        switch action {
        case "state":
            break
        case "wifi":
            do { try CWWiFiClient.shared().interface()?.setPower(on) } catch { problem = "Wi-Fi: \(error.localizedDescription)" }
        case "bluetooth":
            if !MacPrivate.setBluetooth(on) { problem = "This Mac won't let Jarvis switch Bluetooth." }
        case "dark":
            if Self.osa("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)") == nil {
                problem = "Allow Jarvis to control System Events (the prompt is on the Mac)."
            }
        case "volume":
            let level = max(0, min(100, J.i(m["value"])))
            Self.osa("set volume output volume \(level) without output muted")
        case "mute":
            Self.osa("set volume \(on ? "with" : "without") output muted")
        case "brightness":
            let value = Float(max(0, min(1, J.d(m["value"]) ?? 0.5)))
            if !MacPrivate.setBrightness(value, display: currentDisplay) {
                problem = "This display's brightness can't be set from here."
            }
        case "media":
            switch J.s(m["key"]) {
            case "next": Self.mediaKey(17)
            case "previous": Self.mediaKey(18)
            default: Self.mediaKey(16)
            }
        case "app":
            let pid = pid_t(J.i(m["pid"]))
            let found: Bool = DispatchQueue.main.sync {
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                app.unhide()
                app.activate(options: [.activateAllWindows])
                return true
            }
            if !found { problem = "That app isn't running any more." }
            appsChanged = true
        case "display":
            let id = CGDirectDisplayID(UInt32(truncatingIfNeeded: J.i(m["id"])))
            problem = Self.blocking { [pipeline] in
                do { try await pipeline?.switchDisplay(to: id); return nil } catch { return error.localizedDescription }
            }
        case "lock":
            MacPrivate.lockScreen()
        case "control_center":
            let opened: Bool = DispatchQueue.main.sync { MainActor.assumeIsolated { Self.openControlCenter() } }
            if !opened { problem = "Couldn't open Control Center (Jarvis needs Accessibility)." }
        case "mission_control":
            Self.missionControl(nil)
        case "show_desktop":
            Self.missionControl("1")
        default:
            problem = "The Mac app doesn't know “\(action)” yet: update Jarvis on the Mac."
        }
        if let problem { reply(["t": "cc_error", "do": action, "error": problem]) }
        // Let the switch settle (Wi-Fi and Bluetooth report the new state a moment later).
        if action != "state" { Thread.sleep(forTimeInterval: action == "app" ? 0.25 : 0.4) }
        reply(state())
        if appsChanged { sendApps() }
    }

    private var currentDisplay: CGDirectDisplayID { pipeline?.displayID ?? CGMainDisplayID() }

    /// Runs async work to the end from this (non-async) queue.
    private static func blocking(_ work: @escaping @Sendable () async -> String?) -> String? {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .timedOut ? "The display didn't switch in time." : box.value
    }

    // MARK: state

    private func state() -> [String: Any] {
        var s: [String: Any] = ["t": "cc_state"]
        if let wifi = CWWiFiClient.shared().interface() {
            s["wifi"] = wifi.powerOn()
            if let name = wifi.ssid() { s["wifi_name"] = name }   // nil without Location access
        }
        if let bt = MacPrivate.bluetooth() { s["bluetooth"] = bt }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        s["dark"] = (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        if let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool {
            s["stage"] = stage
        }
        if let out = Self.osa("set v to get volume settings\nreturn ((output volume of v) as text) & \",\" & ((output muted of v) as text)") {
            let parts = out.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let v = parts.first.flatMap({ Int($0) }) { s["volume"] = v }
            if parts.count > 1 { s["muted"] = parts[1] == "true" }
        }
        if let b = MacPrivate.brightness(display: currentDisplay) { s["brightness"] = Double(b) }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            s["locked"] = J.b(session["CGSSessionScreenIsLocked"])
        }
        let now: [String: Any]? = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                MusicController.shared.now.map {
                    ["title": $0.title, "artist": $0.artist, "playing": $0.isPlaying, "app": $0.player.app]
                }
            }
        }
        if let now { s["now"] = now }
        s["displays"] = Self.displays()
        s["display"] = Int(currentDisplay)
        return s
    }

    /// The Mac's displays, the main one first: id, name, size in points.
    static func displays() -> [[String: Any]] {
        DispatchQueue.main.sync {
            let main = CGMainDisplayID()
            return NSScreen.screens.compactMap { screen -> [String: Any]? in
                guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let id = CGDirectDisplayID(n.uint32Value)
                return ["id": Int(id), "name": screen.localizedName, "main": id == main,
                        "w": Int(screen.frame.width), "h": Int(screen.frame.height)]
            }
            .sorted { J.b($0["main"]) && !J.b($1["main"]) }
        }
    }

    private struct RunningApp {
        let pid: pid_t, name: String, bundle: String, active: Bool, hidden: Bool
        let icon: NSImage?
    }

    /// The open apps (the Dock's running ones), then each icon this viewer lacks.
    private func sendApps() {
        let own = Bundle.main.bundleIdentifier
        let apps: [RunningApp] = DispatchQueue.main.sync {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
                .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App",
                                  bundle: $0.bundleIdentifier ?? "pid\($0.processIdentifier)",
                                  active: $0.isActive, hidden: $0.isHidden, icon: $0.icon) }
        }
        reply(["t": "cc_apps", "apps": apps.map {
            ["pid": Int($0.pid), "name": $0.name, "bundle": $0.bundle, "active": $0.active, "hidden": $0.hidden]
        }])
        for app in apps where !sentIcons.contains(app.bundle) {
            guard let icon = app.icon, let png = Self.png(icon, side: 96) else { continue }
            sentIcons.insert(app.bundle)
            reply(["t": "cc_icon", "bundle": app.bundle, "png": png.base64EncodedString()])
        }
    }

    static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: helpers

    /// osascript's output (trimmed), nil when it failed or took over 8 s.
    @discardableResult
    static func osa(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A media key (NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18): goes to whatever app plays.
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Mission Control (no argument) or Show Desktop ("1").
    static func missionControl(_ arg: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        p.arguments = arg.map { [$0] } ?? []
        try? p.run()
    }

    /// Clicks the menu bar's Control Center (Accessibility), where AirDrop, Focus,
    /// Stage Manager and Screen Mirroring are switched — macOS lets no app do those.
    @MainActor
    static func openControlCenter() -> Bool {
        guard AXIsProcessTrusted(),
              let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return false }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        for item in (kids as? [AXUIElement]) ?? [] {
            var ident: CFTypeRef?
            AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &ident)
            if (ident as? String) == "com.apple.menuextra.controlcenter" {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }
}

/// macOS calls with no public API (what blueutil, brightness tools and the lock
/// menu item use), looked up at run time: a missing symbol is a nil / false, never a crash.
enum MacPrivate {
    nonisolated(unsafe) private static let bluetoothLib =
        dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    nonisolated(unsafe) private static let displayLib =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    nonisolated(unsafe) private static let loginLib =
        dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)

    private static func sym<T>(_ lib: UnsafeMutableRawPointer?, _ name: String, as: T.Type) -> T? {
        guard let lib, let f = dlsym(lib, name) else { return nil }
        return unsafeBitCast(f, to: T.self)
    }

    static func bluetooth() -> Bool? {
        typealias Get = @convention(c) () -> Int32
        return sym(bluetoothLib, "IOBluetoothPreferenceGetControllerPowerState", as: Get.self).map { $0() != 0 }
    }

    static func setBluetooth(_ on: Bool) -> Bool {
        typealias Set = @convention(c) (Int32) -> Void
        guard let set = sym(bluetoothLib, "IOBluetoothPreferenceSetControllerPowerState", as: Set.self) else { return false }
        set(on ? 1 : 0)
        return true
    }

    static func brightness(display: CGDirectDisplayID) -> Float? {
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let get = sym(displayLib, "DisplayServicesGetBrightness", as: Get.self) else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    static func setBrightness(_ value: Float, display: CGDirectDisplayID) -> Bool {
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
        guard let set = sym(displayLib, "DisplayServicesSetBrightness", as: Set.self) else { return false }
        return set(display, value) == 0
    }

    static func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        if let lock = sym(loginLib, "SACLockScreenImmediate", as: Lock.self) {
            _ = lock()
            return
        }
        // ⌃⌘Q, the system's Lock Screen shortcut.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }
}
