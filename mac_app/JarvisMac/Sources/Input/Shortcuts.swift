import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored as text ("ctrl+opt+space") and shown the
/// Mac way ("⌃⌥Space"). A shortcut needs at least one modifier.
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
    ]

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
        guard let code, !mods.isEmpty else { return nil }
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

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(_ bindings: [(Shortcut, () -> Void)]) {
        unregisterAll()
        installHandler()
        for (i, (shortcut, action)) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4A525653), id: id)  // 'JRVS'
            if RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                handlers[id] = action
            }
        }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
