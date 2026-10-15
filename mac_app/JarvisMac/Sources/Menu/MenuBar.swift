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
    var onFlow: (() -> Void)?
    var onNotes: (() -> Void)?

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
        // The panel holds the microphone while open: "Hey Jarvis" steps aside.
        NotificationCenter.default.post(name: .jarvisVoicePanelOpened, object: nil)
    }

    /// Opens the voice panel (never closes it): what "Hey Jarvis" calls.
    func showVoice() {
        if let popover, popover.isShown { return }
        NSApp.activate()
        toggleVoice()
    }

    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .jarvisVoicePanelClosed, object: nil)
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
        menu.autoenablesItems = false
        model.refreshRoster()   // fresh for next time; this menu shows what's cached
        let connection = model.connected ? (model.roster?.statusLine ?? "Connected") : "Jarvis isn't running (jc-client)"
        let status = NSMenuItem(title: "● " + connection, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let agents = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        agents.isEnabled = false
        menu.addItem(agents)
        if let rows = model.roster?.rows, !rows.isEmpty {
            menu.addItem(.separator())
            for row in rows { menu.addItem(rosterItem(row)) }
        }
        menu.addItem(.separator())
        add(menu, "Show the island", #selector(showIsland))
        add(menu, "Talk to Jarvis", #selector(talk))
        add(menu, "Weekly recap", #selector(recap))
        add(menu, "Flow…", #selector(flow))
        add(menu, "Notes…", #selector(notes))
        add(menu, NoteTaker.shared.isRecording ? "Stop recording the call" : "Record a call", #selector(recordCall))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(settings), key: ",")
        if NSClassFromString("JarvisVoiceUI.JarvisVoicePanel") ?? NSClassFromString("JarvisVoicePanel") != nil
            || model.voiceDylib != nil {
            add(menu, "Jarvis settings…", #selector(jarvisSettings))
        }
        add(menu, "Open dashboard", #selector(dashboard))
        add(menu, "Voice Orb in a window", #selector(voiceWindow))
        add(menu, "Re-pair…", #selector(repair))
        add(menu, "View logs", #selector(logs))
        add(menu, "Restart", #selector(restart))
        add(menu, "Demo", #selector(demo))
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
    @objc private func flow() { onFlow?() }
    @objc private func notes() { onNotes?() }
    @objc private func recordCall() {
        let recording = NoteTaker.shared.isRecording
        NoteTaker.shared.toggle()
        if !recording { onNotes?() }
    }
    @objc private func demo() { onDemo?() }
    @objc private func dashboard() { model.trayAction("dashboard") }
    @objc private func voiceWindow() { model.trayAction("voice_window") }
    @objc private func repair() { model.trayAction("repair") }
    @objc private func logs() { model.trayAction("logs") }
    @objc private func restart() { model.trayAction("restart") }

    /// Jarvis's own settings window, from the voice panel's library.
    @objc private func jarvisSettings() {
        _ = makeVoicePanel()   // loads the library if it isn't yet
        if let cls = (NSClassFromString("JarvisVoiceUI.JarvisVoicePanel") ?? NSClassFromString("JarvisVoicePanel"))
            as? NSObject.Type, cls.responds(to: NSSelectorFromString("showSettings")) {
            _ = cls.perform(NSSelectorFromString("showSettings"))
        } else {
            model.trayAction("dashboard")
        }
    }

    /// One device or wearable: its picture, its name, what it's doing and a status dot.
    private func rosterItem(_ row: MacRoster.Row) -> NSMenuItem {
        if row.header {
            let header = NSMenuItem(title: row.name.uppercased(), action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(string: row.name.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            header.isEnabled = false
            return header
        }
        let item = NSMenuItem(title: row.name, action: #selector(noop), keyEquivalent: "")
        item.target = self
        let text = NSMutableAttributedString(string: row.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !row.detail.isEmpty {
            text.append(NSAttributedString(string: "   " + row.detail, attributes: [
                .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        text.append(NSAttributedString(string: "  ●", attributes: [
            .font: NSFont.menuFont(ofSize: 10),
            .foregroundColor: row.online ? NSColor.systemGreen : NSColor.tertiaryLabelColor]))
        item.attributedTitle = text
        if let path = row.image, let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            item.image = image
        } else if !row.symbol.isEmpty {
            item.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func noop() {}
    @objc private func settings() { onSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
