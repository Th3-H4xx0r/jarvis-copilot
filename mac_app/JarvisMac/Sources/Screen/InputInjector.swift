import AppKit
import CoreGraphics
import QuartzCore
import Foundation

/// The viewer's mouse and keys (data channel "input", Contract B) as real events
/// on the shared display. Coordinates arrive normalised (0…1) to that display.
///
///   {"t":"move","x","y"}  {"t":"down"|"up","x","y","button"}  {"t":"click","x","y","button","count"}
///   {"t":"scroll","dx","dy"}  {"t":"key","key","mods","code"?}  {"t":"text","text"}
///
/// Keys: `key` is a KeyboardEvent.key-style name or a character; `code` (optional,
/// the web's KeyboardEvent.code: "KeyF", "Digit1", "BracketLeft", "Delete"…) names
/// the physical key and wins for shortcuts (⌘/⌥/⌃ held — the key's character is
/// then "ƒ" or "{", not the key) and for named keys. "Backspace" deletes back,
/// "ForwardDelete" deletes forward; a bare "Delete" with no `code` is backspace
/// (the iPhone's ⌫), with `code` "Delete" it is forward delete (a PC's Del key).
///
/// Posting events needs Accessibility (the same grant dictation and push to talk use).
final class InputInjector: @unchecked Sendable {
    private let bounds: CGRect
    private let lock = NSLock()
    private var held: CGMouseButton?
    private var lastPoint: CGPoint
    private var warned = false
    // Down/up pairs from a viewer become double and triple clicks the way a real mouse does.
    private var lastDown: (at: CFTimeInterval, point: CGPoint, button: CGMouseButton)?
    private var clicks = 1

    init(bounds: CGRect) {
        self.bounds = bounds
        lastPoint = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Point on the display (global, top-left origin — what CGEvent takes).
    func point(x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + cx * bounds.width, y: bounds.minY + cy * bounds.height)
    }

    /// Runs one message. Returns a problem to tell the viewer about (once), else nil.
    func handle(_ m: [String: Any]) -> String? {
        guard AXIsProcessTrusted() else {
            lock.lock()
            defer { lock.unlock() }
            guard !warned else { return nil }
            warned = true
            DispatchQueue.main.async {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            return "Jarvis can't control this Mac yet: allow it under Privacy & Security → Accessibility."
        }
        lock.lock()
        defer { lock.unlock() }
        let src = CGEventSource(stateID: .hidSystemState)
        let kind = J.s(m["t"])
        let button: CGMouseButton = J.s(m["button"]) == "right" ? .right : .left
        func at() -> CGPoint {
            if let x = J.d(m["x"]), let y = J.d(m["y"]) { lastPoint = point(x: x, y: y) }
            return lastPoint
        }
        switch kind {
        case "move":
            let p = at()
            let type: CGEventType = held == .left ? .leftMouseDragged : held == .right ? .rightMouseDragged : .mouseMoved
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: held ?? .left)?
                .post(tap: .cghidEventTap)
        case "down":
            let p = at()
            held = button
            let now = CACurrentMediaTime()
            if let last = lastDown, last.button == button, now - last.at <= NSEvent.doubleClickInterval,
               hypot(p.x - last.point.x, p.y - last.point.y) < 6 {
                clicks = min(3, clicks + 1)
            } else {
                clicks = 1
            }
            lastDown = (now, p, button)
            mouse(src, button, down: true, at: p, clicks: clicks)
        case "up":
            let p = at()
            held = nil
            mouse(src, button, down: false, at: p, clicks: clicks)
        case "click":
            let p = at()
            let count = max(1, min(3, J.i(m["count"]) == 0 ? 1 : J.i(m["count"])))
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            for n in 1...count {
                mouse(src, button, down: true, at: p, clicks: n)
                mouse(src, button, down: false, at: p, clicks: n)
            }
        case "scroll":
            // Browser deltas (positive = content moves up / scroll down); CGEvent's wheel is the other way.
            let dy = Int32(max(-2000, min(2000, -(J.d(m["dy"]) ?? 0))))
            let dx = Int32(max(-2000, min(2000, -(J.d(m["dx"]) ?? 0))))
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
                .post(tap: .cghidEventTap)
        case "key":
            key(src, J.s(m["key"]), code: J.s(m["code"]), mods: (m["mods"] as? [String]) ?? [])
        case "text":
            type(src, J.s(m["text"]))
        default:
            break
        }
        return nil
    }

    private func mouse(_ src: CGEventSource?, _ button: CGMouseButton, down: Bool, at p: CGPoint, clicks: Int) {
        let type: CGEventType
        switch (button, down) {
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .leftMouseDown
        default: type = .leftMouseUp
        }
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e?.post(tap: .cghidEventTap)
    }

    static func flags(_ mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command", "meta": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt", "option", "opt": f.insert(.maskAlternate)
            case "ctrl", "control": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    private func key(_ src: CGEventSource?, _ name: String, code physical: String, mods: [String]) {
        let flags = Self.flags(mods)
        let shortcut = !flags.subtracting(.maskShift).isEmpty
        // A plain character (maybe shifted: "A", "?") is typed as itself, so the case
        // and the layout come out right; shortcuts (⌘C…) go by key code.
        if name.count == 1, name != " ", !shortcut {
            type(src, name)
            return
        }
        guard let code = Self.keyCode(name, code: physical, shortcut: shortcut) else {
            // A character with no key on the US layout (é, emoji…): type it instead.
            if flags.isEmpty, !name.isEmpty { type(src, name) }
            return
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private func type(_ src: CGEventSource?, _ text: String) {
        let units = Array(text.prefix(4000).utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    /// The key to press: the physical `code` for shortcuts and named keys when the
    /// viewer sent one, else the `key` name / character.
    static func keyCode(_ name: String, code: String, shortcut: Bool) -> CGKeyCode? {
        if !code.isEmpty, shortcut || name.count != 1, let c = physicalKeyCode(code) { return c }
        return keyCode(name)
    }

    /// macOS virtual key codes (ANSI) for KeyboardEvent.code values.
    static func physicalKeyCode(_ code: String) -> CGKeyCode? {
        if code.hasPrefix("Key"), code.count == 4 { return keyCode(String(code.dropFirst(3)).lowercased()) }
        if code.hasPrefix("Digit"), code.count == 6 { return keyCode(String(code.dropFirst(5))) }
        let codes: [String: CGKeyCode] = [
            "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30, "Backslash": 42,
            "Semicolon": 41, "Quote": 39, "Backquote": 50, "Comma": 43, "Period": 47, "Slash": 44,
            "IntlBackslash": 10, "Space": 49, "Enter": 36, "NumpadEnter": 76, "Tab": 48,
            "Backspace": 51, "Delete": 117, "Escape": 53, "Home": 115, "End": 119,
            "PageUp": 116, "PageDown": 121, "ArrowLeft": 123, "ArrowRight": 124,
            "ArrowDown": 125, "ArrowUp": 126,
        ]
        if let c = codes[code] { return c }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...12).contains(n) { return keyCode("f\(n)") }
        return nil
    }

    /// macOS virtual key codes (ANSI layout) for KeyboardEvent.key names and plain characters.
    /// "delete" is backspace (the iPhone's ⌫); "forwarddelete" deletes forward.
    static func keyCode(_ name: String) -> CGKeyCode? {
        let named: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, " ": 49, "backspace": 51, "delete": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116,
            "pagedown": 121, "arrowleft": 123, "left": 123, "arrowright": 124, "right": 124,
            "arrowdown": 125, "down": 125, "arrowup": 126, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        if let c = named[name.lowercased()] { return c }
        guard name.count == 1, let ch = name.lowercased().first else { return nil }
        let chars: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
        ]
        return chars[ch]
    }
}
