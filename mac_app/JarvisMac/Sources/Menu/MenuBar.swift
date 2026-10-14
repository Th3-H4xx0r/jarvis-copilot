import AppKit
import SwiftUI

/// The Jarvis menu-bar item. Left click: the voice panel (the same SwiftUI
/// panel the tray used to host, loaded from jc-client's libJarvisVoiceUI.dylib
/// and pointed at the loopback proxy, so it needs no credentials of its own).
/// Right click: the menu.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let island: IslandController
    private var popover: NSPopover?
    private var voiceLoaded = false
    var onSettings: (() -> Void)?
    var onDemo: (() -> Void)?
    var onRecap: (() -> Void)?

    init(model: AppModel, island: IslandController) {
        self.model = model
        self.island = island
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Jarvis")
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggleVoice()
        }
    }

    // MARK: voice panel

    func toggleVoice() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let vc = makeVoicePanel(), let button = item.button else {
            island.toggle()  // no panel available: the island instead
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.contentSize = NSSize(width: 320, height: 438)
        p.delegate = self
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = p
    }

    private func makeVoicePanel() -> NSViewController? {
        guard let origin = model.apiOrigin else { return nil }
        if !voiceLoaded, let path = model.voiceDylib, FileManager.default.fileExists(atPath: path) {
            voiceLoaded = dlopen(path, RTLD_NOW) != nil
        }
        guard voiceLoaded, let cls = NSClassFromString("JarvisVoiceUI.JarvisVoicePanel") ?? NSClassFromString("JarvisVoicePanel")
        else { return nil }
        let sel = NSSelectorFromString("makeViewControllerWithBaseURL:showsOpenInWindow:")
        guard let meta = cls as AnyObject as? NSObjectProtocol, meta.responds(to: sel) else { return nil }
        typealias Make = @convention(c) (AnyObject, Selector, NSString, Bool) -> NSViewController?
        let imp = (cls as AnyObject).method(for: sel)
        let make = unsafeBitCast(imp, to: Make.self)
        return make(cls as AnyObject, sel, origin as NSString, false)
    }

    // MARK: menu

    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: model.connected ? statusLine : "Jarvis isn't running (jc-client)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add(menu, "Show the island", #selector(showIsland))
        add(menu, "Talk to Jarvis", #selector(talk))
        add(menu, "Weekly recap", #selector(recap))
        menu.addItem(.separator())
        add(menu, "Demo", #selector(demo))
        add(menu, "Settings…", #selector(settings), key: ",")
        menu.addItem(.separator())
        add(menu, "Quit Jarvis", #selector(quit), key: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private var statusLine: String {
        if model.waitingCount > 0 { return "\(model.waitingCount) agent\(model.waitingCount == 1 ? "" : "s") waiting on you" }
        if model.workingCount > 0 { return "\(model.workingCount) working" }
        return "\(model.sessions.count) agent session\(model.sessions.count == 1 ? "" : "s")"
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc private func showIsland() { island.attention() }
    @objc private func talk() { toggleVoice() }
    @objc private func recap() { onRecap?() }
    @objc private func demo() { onDemo?() }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
