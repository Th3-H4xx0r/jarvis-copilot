import SwiftUI

/// Ctrl / Alt / Win / Shift latch until the next key (as on a phone's own keyboard): tap Ctrl,
/// then C sends Ctrl+C. Pure, for the tests.
struct RdpModifiers: Equatable {
    private(set) var latched: [RdpKeyCode] = []

    static let all: [RdpKeyCode] = [.ctrl, .alt, .shift, .win]

    func isOn(_ key: RdpKeyCode) -> Bool { latched.contains(key) }

    mutating func toggle(_ key: RdpKeyCode) {
        if let i = latched.firstIndex(of: key) { latched.remove(at: i) } else { latched.append(key) }
    }

    /// The key events for one press of `key` with whatever is latched: modifiers down, the key,
    /// modifiers up in reverse. Clears the latch.
    mutating func events(for key: RdpKeyCode) -> [(RdpKeyCode, Bool)] {
        let mods = latched
        latched = []
        return mods.map { ($0, true) } + [(key, true), (key, false)] + mods.reversed().map { ($0, false) }
    }

    /// A chord sent as is (Ctrl+Alt+Del, Ctrl+C): every key down in order, up in reverse.
    static func chord(_ keys: [RdpKeyCode]) -> [(RdpKeyCode, Bool)] {
        keys.map { ($0, true) } + keys.reversed().map { ($0, false) }
    }
}

/// The bar under the desktop: the keyboard, Esc, Tab, the latched modifiers, arrows and the
/// shortcuts a phone keyboard can't type. The app's grey controls; a latched modifier is the
/// selected grey.
struct RdpKeyboardBar: View {
    let client: RdpClient?
    @Binding var modifiers: RdpModifiers
    @Binding var keyboardUp: Bool
    let pasteToPC: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(symbol: keyboardUp ? "keyboard.chevron.compact.down" : "keyboard", label: "Keyboard",
                    selected: keyboardUp) { keyboardUp.toggle() }
                divider
                key("Esc") { send(.escape) }
                key("Tab") { send(.tab) }
                modifier("Ctrl", .ctrl)
                modifier("Alt", .alt)
                modifier("Shift", .shift)
                key(symbol: "squareshape.split.2x2", label: "Windows key", selected: modifiers.isOn(.win)) { modifiers.toggle(.win) }
                divider
                key(symbol: "arrow.left", label: "Left") { send(.left) }
                key(symbol: "arrow.up", label: "Up") { send(.up) }
                key(symbol: "arrow.down", label: "Down") { send(.down) }
                key(symbol: "arrow.right", label: "Right") { send(.right) }
                divider
                key("Ctrl+Alt+Del") { chord([.ctrl, .alt, .delete]) }
                key(symbol: "doc.on.doc", label: "Copy (Ctrl+C)") { chord([.ctrl, .c]) }
                key(symbol: "doc.on.clipboard", label: "Paste this iPhone's clipboard") { pasteToPC() }
                key(symbol: "arrow.uturn.backward", label: "Undo (Ctrl+Z)") { chord([.ctrl, .z]) }
                key("Alt+F4") { chord([.alt, .f4]) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(JcTheme.bg.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(JcTheme.border).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(JcTheme.border).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    private func send(_ k: RdpKeyCode) {
        for (code, down) in modifiers.events(for: k) { client?.key(code, down: down) }
    }

    private func chord(_ keys: [RdpKeyCode]) {
        for (code, down) in RdpModifiers.chord(keys) { client?.key(code, down: down) }
    }

    private func modifier(_ title: String, _ k: RdpKeyCode) -> some View {
        key(title, selected: modifiers.isOn(k)) { modifiers.toggle(k) }
    }

    private func key(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcButton.label)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(selected ? JcButton.selectedFill : JcButton.fill,
                            in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func key(symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcButton.label)
                .frame(width: 40, height: 36)
                .background(selected ? JcButton.selectedFill : JcButton.fill,
                            in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
