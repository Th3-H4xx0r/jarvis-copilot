import AppKit
import SwiftUI

/// One entry in a chip's menu.
struct ChipMenuEntry {
    enum Kind { case item, header, separator }

    var kind: Kind = .item
    var title: String = ""
    var checked: Bool = false
    var enabled: Bool = true
    var action: () -> Void = {}

    static func separator() -> ChipMenuEntry { ChipMenuEntry(kind: .separator) }
    static func header(_ title: String) -> ChipMenuEntry {
        ChipMenuEntry(kind: .header, title: title, enabled: false)
    }
}

/// A small pull-down chip: a symbol, a word, and a menu.
///
/// An `NSPopUpButton` in pull-down mode, which is the control AppKit provides
/// for exactly this. Two other things were tried and neither works here:
///
///  * SwiftUI's `Menu` hit-tests against the GLYPHS of its label and ignores
///    what `padding`, `frame` and `contentShape` say about it. Measured: the
///    model chip's target was 9.5 × 11.5 points — the sparkles icon alone, the
///    word beside it inert. A target that size is one most clicks miss, so the
///    picker read as broken rather than small.
///  * An `NSButton` that pops a menu from its action. The target is then the
///    whole chip, but a button's action fires on mouse-UP, by which point there
///    is no press for the menu to track — press-and-hold did nothing at all.
///
/// A pull-down button opens on mouse-down and tracks the drag, the way every
/// other menu on the system does.
///
/// `isBordered = false` is what makes it blend: no bezel, no arrow, nothing but
/// the label sitting in the panel until it is used.
///
/// The menu is rebuilt in `menuNeedsUpdate`, not stored: it must show what is
/// true when it OPENS — sessions that have since loaded, the model now
/// selected — and that is exactly what the delegate callback is for.
struct MacMenuChip: NSViewRepresentable {
    let symbol: String
    let text: String
    var enabled: Bool = true
    var help: String = ""
    var accessibilityLabel: String = ""
    let entries: () -> [ChipMenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .medium)
        button.imagePosition = .imageLeading
        button.autoenablesItems = false
        let menu = NSMenu()
        menu.delegate = context.coordinator
        button.menu = menu
        context.coordinator.refreshTitle(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        button.toolTip = help.isEmpty ? nil : help
        button.setAccessibilityLabel(accessibilityLabel.isEmpty ? text : accessibilityLabel)
        button.contentTintColor = NSColor.white.withAlphaComponent(enabled ? 0.75 : 0.35)
        context.coordinator.refreshTitle(button)
    }

    /// As wide as the label needs, up to a third of the panel: a model id or a
    /// chat title is easily longer than the row has room for.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton,
                      context: Context) -> CGSize? {
        CGSize(width: min(nsView.intrinsicContentSize.width, 112), height: 18)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: MacMenuChip
        init(_ parent: MacMenuChip) { self.parent = parent }

        /// A pull-down button shows item 0 and never selects it, so item 0 is
        /// the chip's own label.
        func refreshTitle(_ button: NSPopUpButton) {
            let title = NSMenuItem(title: parent.text, action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: parent.symbol, accessibilityDescription: nil)
            if button.menu?.items.isEmpty == false {
                button.menu?.removeAllItems()
            }
            button.menu?.addItem(title)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let title = menu.items.first
            menu.removeAllItems()
            if let title { menu.addItem(title) }
            for entry in parent.entries() {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .header:
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                case .item:
                    let item = NSMenuItem(title: entry.title,
                                          action: #selector(pick(_:)), keyEquivalent: "")
                    item.target = self
                    item.isEnabled = entry.enabled
                    item.state = entry.checked ? .on : .off
                    item.representedObject = Action(entry.action)
                    menu.addItem(item)
                }
            }
        }

        @objc private func pick(_ sender: NSMenuItem) {
            (sender.representedObject as? Action)?.run()
        }

        /// `representedObject` takes an object, and a closure is not one.
        private final class Action {
            private let body: () -> Void
            init(_ body: @escaping () -> Void) { self.body = body }
            func run() { body() }
        }
    }
}
