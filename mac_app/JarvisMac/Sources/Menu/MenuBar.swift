import AppKit
import SwiftUI

/// Jarvis's menu — what the menu-bar icon used to show, now popped by a
/// right-click on the notch (Jarvis on the Mac lives only in the notch). It
/// also loads the voice panel (from jc-client's libJarvisVoiceUI.dylib,
/// pointed at the loopback proxy, so it needs no credentials of its own) for
/// the island's Voice view and the "Voice Orb in a window" window.
@MainActor
final class JarvisMenu: NSObject {
    private let model: AppModel
    private let island: IslandController
    private var voiceLoaded = false
    private var voiceWindow: NSWindow?
    var onSettings: (() -> Void)?
    var onDemo: (() -> Void)?
    var onRecap: (() -> Void)?
    var onFlow: (() -> Void)?
    var onNotes: (() -> Void)?

    init(model: AppModel, island: IslandController) {
        self.model = model
        self.island = island
        super.init()
    }

    /// Pops the menu where you right-clicked.
    func popUp(in view: NSView, at point: NSPoint) {
        model.refreshRoster()   // fresh for next time; this menu shows what's cached
        build().popUp(positioning: nil, at: point, in: view)
    }

    // MARK: voice panel

    /// The voice panel in its own window ("Voice Orb in a window").
    func showVoiceWindow() {
        if let voiceWindow, voiceWindow.isVisible {
            voiceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let vc = makeVoicePanel() else { return island.openVoice() }
        let w = NSWindow(contentViewController: vc)
        w.title = "Jarvis"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 320, height: 438))
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            NotificationCenter.default.post(name: .jarvisVoicePanelClosed, object: nil)
        }
        voiceWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The panel holds the microphone while open: "Hey Jarvis" steps aside.
        NotificationCenter.default.post(name: .jarvisVoicePanelOpened, object: nil)
    }

    /// The voice panel from jc-client's dylib. `island`: the wide layout for the
    /// notch (one stage, controls at its edges); an older dylib without it gets
    /// the popover layout.
    func makeVoicePanel(island: Bool = false) -> NSViewController? {
        guard let origin = model.apiOrigin, let cls = voicePanelClass(),
              let meta = cls as AnyObject as? NSObjectProtocol
        else { return nil }
        let islandSel = NSSelectorFromString("makeIslandViewControllerWithBaseURL:")
        if island, meta.responds(to: islandSel) {
            typealias MakeIsland = @convention(c) (AnyObject, Selector, NSString) -> NSViewController?
            let make = unsafeBitCast((cls as AnyObject).method(for: islandSel), to: MakeIsland.self)
            return make(cls as AnyObject, islandSel, origin as NSString)
        }
        let sel = NSSelectorFromString("makeViewControllerWithBaseURL:showsOpenInWindow:")
        guard meta.responds(to: sel) else { return nil }
        typealias Make = @convention(c) (AnyObject, Selector, NSString, Bool) -> NSViewController?
        let make = unsafeBitCast((cls as AnyObject).method(for: sel), to: Make.self)
        return make(cls as AnyObject, sel, origin as NSString, false)
    }

    /// jc-client's dylib's `JarvisVoicePanel` class, loading the dylib the first time.
    func voicePanelClass() -> AnyClass? {
        if !voiceLoaded, let path = model.voiceDylib, FileManager.default.fileExists(atPath: path) {
            voiceLoaded = dlopen(path, RTLD_NOW) != nil
        }
        guard voiceLoaded else { return nil }
        return NSClassFromString("JarvisVoiceUI.JarvisVoicePanel") ?? NSClassFromString("JarvisVoicePanel")
    }

    // MARK: menu

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
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
        add(menu, "Voice Orb in a window", #selector(openVoiceWindow))
        add(menu, "Re-pair…", #selector(repair))
        add(menu, "View logs", #selector(logs))
        add(menu, "Restart", #selector(restart))
        add(menu, "Demo", #selector(demo))
        menu.addItem(.separator())
        add(menu, "Quit Jarvis", #selector(quit), key: "q")
        return menu
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
    @objc private func talk() { island.openVoice() }
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
    @objc private func openVoiceWindow() { showVoiceWindow() }
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

/// The voice panel's orb, across the dylib boundary, for the island's orb
/// flight: hide it while the notch's orb flies in (`setIslandOrbHidden:`), and
/// hear where it sits (the panel posts its frame). An older dylib has neither;
/// Voice then opens without a flight.
enum VoicePanelOrb {
    static let frameNotification = Notification.Name("JarvisVoicePanelIslandOrbFrame")

    @MainActor
    static func setHidden(_ hidden: Bool, on cls: AnyClass?) -> Bool {
        let sel = NSSelectorFromString("setIslandOrbHidden:")
        guard let cls, let meta = cls as AnyObject as? NSObjectProtocol, meta.responds(to: sel) else { return false }
        _ = meta.perform(sel, with: NSNumber(value: hidden))
        return true
    }
}

/// Hold-to-talk across the dylib boundary: the voice panel starts listening
/// when the shortcut goes down and sends what was said when it comes up
/// (`holdToTalkBegan` / `holdToTalkEnded`). An older dylib has neither: the
/// voice view just opens.
enum VoicePanelTalk {
    @MainActor
    static func began(on cls: AnyClass?) { call("holdToTalkBegan", on: cls) }

    @MainActor
    static func ended(on cls: AnyClass?) { call("holdToTalkEnded", on: cls) }

    @MainActor
    private static func call(_ name: String, on cls: AnyClass?) {
        let sel = NSSelectorFromString(name)
        guard let cls, let meta = cls as AnyObject as? NSObjectProtocol, meta.responds(to: sel) else { return }
        _ = meta.perform(sel)
    }
}
