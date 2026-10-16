import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored as text ("ctrl+opt+space") and shown the
/// Mac way ("⌃⌥Space"). A shortcut needs at least one modifier — except a lone
/// function key (F13 is a fine push-to-talk key), which steals no typing.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    private static let keys: [(String, UInt32, String)] = [
        ("space", UInt32(kVK_Space), "Space"), ("return", UInt32(kVK_Return), "↩"),
        ("tab", UInt32(kVK_Tab), "⇥"), ("esc", UInt32(kVK_Escape), "⎋"),
        ("[", UInt32(kVK_ANSI_LeftBracket), "["), ("]", UInt32(kVK_ANSI_RightBracket), "]"),
        ("a", UInt32(kVK_ANSI_A), "A"), ("b", UInt32(kVK_ANSI_B), "B"), ("c", UInt32(kVK_ANSI_C), "C"),
        ("d", UInt32(kVK_ANSI_D), "D"), ("e", UInt32(kVK_ANSI_E), "E"), ("f", UInt32(kVK_ANSI_F), "F"),
        ("g", UInt32(kVK_ANSI_G), "G"), ("h", UInt32(kVK_ANSI_H), "H"), ("i", UInt32(kVK_ANSI_I), "I"),
        ("j", UInt32(kVK_ANSI_J), "J"), ("k", UInt32(kVK_ANSI_K), "K"), ("l", UInt32(kVK_ANSI_L), "L"),
        ("m", UInt32(kVK_ANSI_M), "M"), ("n", UInt32(kVK_ANSI_N), "N"), ("o", UInt32(kVK_ANSI_O), "O"),
        ("p", UInt32(kVK_ANSI_P), "P"), ("q", UInt32(kVK_ANSI_Q), "Q"), ("r", UInt32(kVK_ANSI_R), "R"),
        ("s", UInt32(kVK_ANSI_S), "S"), ("t", UInt32(kVK_ANSI_T), "T"), ("u", UInt32(kVK_ANSI_U), "U"),
        ("v", UInt32(kVK_ANSI_V), "V"), ("w", UInt32(kVK_ANSI_W), "W"), ("x", UInt32(kVK_ANSI_X), "X"),
        ("y", UInt32(kVK_ANSI_Y), "Y"), ("z", UInt32(kVK_ANSI_Z), "Z"),
        ("1", UInt32(kVK_ANSI_1), "1"), ("2", UInt32(kVK_ANSI_2), "2"), ("3", UInt32(kVK_ANSI_3), "3"),
        ("4", UInt32(kVK_ANSI_4), "4"), ("5", UInt32(kVK_ANSI_5), "5"), ("6", UInt32(kVK_ANSI_6), "6"),
        ("7", UInt32(kVK_ANSI_7), "7"), ("8", UInt32(kVK_ANSI_8), "8"), ("9", UInt32(kVK_ANSI_9), "9"),
        ("0", UInt32(kVK_ANSI_0), "0"),
        ("-", UInt32(kVK_ANSI_Minus), "-"), ("=", UInt32(kVK_ANSI_Equal), "="),
        (";", UInt32(kVK_ANSI_Semicolon), ";"), ("'", UInt32(kVK_ANSI_Quote), "'"),
        (",", UInt32(kVK_ANSI_Comma), ","), (".", UInt32(kVK_ANSI_Period), "."),
        ("/", UInt32(kVK_ANSI_Slash), "/"), ("\\", UInt32(kVK_ANSI_Backslash), "\\"),
        ("`", UInt32(kVK_ANSI_Grave), "`"),
        ("left", UInt32(kVK_LeftArrow), "←"), ("right", UInt32(kVK_RightArrow), "→"),
        ("up", UInt32(kVK_UpArrow), "↑"), ("down", UInt32(kVK_DownArrow), "↓"),
        ("delete", UInt32(kVK_Delete), "⌫"), ("fwddelete", UInt32(kVK_ForwardDelete), "⌦"),
        ("home", UInt32(kVK_Home), "↖"), ("end", UInt32(kVK_End), "↘"),
        ("pageup", UInt32(kVK_PageUp), "⇞"), ("pagedown", UInt32(kVK_PageDown), "⇟"),
    ] + functionKeys

    /// F1–F20: the keys a shortcut may use on their own.
    private static let functionKeys: [(String, UInt32, String)] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].enumerated().map { i, code in ("f\(i + 1)", UInt32(code), "F\(i + 1)") }

    /// A key a shortcut can be made of.
    static func knows(_ keyCode: UInt32) -> Bool { keys.contains { $0.1 == keyCode } }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool { functionKeys.contains { $0.1 == keyCode } }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    init?(string: String) {
        var mods: NSEvent.ModifierFlags = []
        var code: UInt32?
        for part in string.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            default:
                guard let key = Self.keys.first(where: { $0.0 == part }) else { return nil }
                code = key.1
            }
        }
        guard let code, !mods.isEmpty || Self.isFunctionKey(code) else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    var string: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.keys.first(where: { $0.1 == keyCode })?.0 ?? "?")
        return parts.joined(separator: "+")
    }

    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + (Self.keys.first(where: { $0.1 == keyCode })?.2 ?? "?")
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

/// Recording a shortcut in Settings: every combo pressed replaces the last
/// (shown as you go), Esc finishes with the last one — or, with nothing
/// pressed, leaves the shortcut as it was. A plain key needs a modifier.
struct ShortcutRecording: Equatable {
    enum Outcome: Equatable {
        case keepGoing
        /// nil: nothing recorded, keep the old shortcut.
        case finished(Shortcut?)
    }

    private(set) var captured: Shortcut?
    /// Why the last key didn't count.
    private(set) var hint: String?

    mutating func key(code: UInt32, modifiers: NSEvent.ModifierFlags) -> Outcome {
        if code == UInt32(kVK_Escape) { return .finished(captured) }
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard Shortcut.knows(code) else {
            hint = String(localized: "That key can't be used — try another.")
            return .keepGoing
        }
        guard !mods.isEmpty || Shortcut.isFunctionKey(code) else {
            hint = String(localized: "Add ⌃, ⌥, ⌘ or ⇧ — a plain key would get in the way of typing.")
            return .keepGoing
        }
        captured = Shortcut(keyCode: code, modifiers: mods)
        hint = nil
        return .keepGoing
    }
}

/// Everything a global shortcut can do. All rebindable in Settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggleIsland, openChat, goToAlert, jumpToTerminal, attachWindow
    case nextSession, previousSession, mute, desktopOrb, nextSkin, talk
    case recordCall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleIsland: return "Show or hide the island"
        case .openChat: return "Open the chat"
        case .goToAlert: return "Go to what needs you"
        case .jumpToTerminal: return "Jump to the session's terminal"
        case .attachWindow: return "Attach the front window to the chat"
        case .nextSession: return "Next session"
        case .previousSession: return "Previous session"
        case .mute: return "Mute sounds"
        case .desktopOrb: return "Orb on the desktop"
        case .nextSkin: return "Next orb look"
        case .talk: return "Talk to Jarvis"
        case .recordCall: return "Record a call (start / stop)"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .toggleIsland, .talk, .recordCall: return nil
        case .openChat: return Shortcut(string: "ctrl+opt+space")
        case .goToAlert: return Shortcut(string: "ctrl+opt+a")
        case .jumpToTerminal: return Shortcut(string: "ctrl+opt+t")
        case .attachWindow: return Shortcut(string: "ctrl+opt+w")
        case .nextSession: return Shortcut(string: "ctrl+opt+]")
        case .previousSession: return Shortcut(string: "ctrl+opt+[")
        case .mute: return Shortcut(string: "ctrl+opt+m")
        case .desktopOrb: return Shortcut(string: "ctrl+opt+d")
        case .nextSkin: return Shortcut(string: "ctrl+opt+g")
        }
    }

    private var defaultsKey: String { "shortcut.\(rawValue)" }

    /// The Shortcuts tab's list. Talk to Jarvis lives in Settings → Voice, next
    /// to its hold-to-talk key.
    static var shortcutsTab: [ShortcutAction] { allCases.filter { $0 != .talk } }

    /// Can be held: Talk to Jarvis listens while the key is down and sends
    /// when you let go; the island shows while it's down.
    var supportsHold: Bool { self == .talk || self == .toggleIsland }

    /// Held rather than pressed (Settings → Shortcuts: Press / Hold).
    var holds: Bool {
        get { supportsHold && UserDefaults.standard.bool(forKey: defaultsKey + ".hold") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey + ".hold") }
    }

    /// Bind `shortcut` here; any other action that had it is switched off.
    /// Returns those actions.
    @discardableResult
    func assign(_ shortcut: Shortcut?) -> [ShortcutAction] {
        var moved: [ShortcutAction] = []
        if let shortcut {
            for other in Self.allCases where other != self && other.shortcut == shortcut {
                other.shortcut = nil
                moved.append(other)
            }
        }
        self.shortcut = shortcut
        return moved
    }

    /// The user's binding, the default if never set, nil when switched off ("").
    var shortcut: Shortcut? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return defaultShortcut }
            return Shortcut(string: raw)
        }
        nonmutating set { UserDefaults.standard.set(newValue?.string ?? "", forKey: defaultsKey) }
    }
}

/// Registers the global shortcuts with Carbon (works without Accessibility).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// What a shortcut does: on press, and (held shortcuts) on release.
    struct Binding {
        let shortcut: Shortcut
        let pressed: () -> Void
        var released: (() -> Void)? = nil
    }

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: Binding] = [:]
    /// Held right now — the key repeats while down; a held action starts once.
    private var down: Set<UInt32> = []
    private var installed = false

    func register(_ bindings: [Binding]) {
        unregisterAll()
        installHandler()
        for (i, binding) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4A525653), id: id)  // 'JRVS'
            if RegisterEventHotKey(binding.shortcut.keyCode, binding.shortcut.carbonModifiers, hotKeyID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                handlers[id] = binding
            }
        }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        // A held action whose key goes away (re-registering, recording) ends.
        for id in down { handlers[id]?.released?() }
        down = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        guard let binding = handlers[id] else { return }
        if pressed {
            guard !down.contains(id) else { return }
            if binding.released != nil { down.insert(id) }
            binding.pressed()
        } else if down.remove(id) != nil {
            binding.released?()
        }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        let specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id, pressed: pressed) } }
            return noErr
        }, specs.count, specs, nil, nil)
    }
}
