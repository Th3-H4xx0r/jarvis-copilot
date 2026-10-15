import AppKit

/// Puts the app together: the link to jc-client, the island, the menu-bar item,
/// the desktop orb and the global shortcuts. Under XCTest it starts nothing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var menuBar: MenuBarController?
    private var desktopOrb: DesktopOrbController?
    private let model = AppModel.shared

    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        guard !Self.anotherCopyRunning() else {
            NSApp.terminate(nil)
            return
        }
        let island = IslandController(model: model)
        self.island = island
        let menuBar = MenuBarController(model: model, island: island)
        menuBar.onSettings = { [weak self] in self.map { SettingsWindow.show(model: $0.model) } }
        menuBar.onDemo = { [weak self] in self.map { DemoEngine.run(model: $0.model, island: island) } }
        menuBar.onRecap = { [weak self] in self.map { RecapWindow.show(model: $0.model) } }
        self.menuBar = menuBar
        desktopOrb = DesktopOrbController(model: model, island: island)

        model.onMoment = { moment, session in
            switch moment {
            case .needsYou:
                island.attention()
                Sounds.play(.needsYou)
            case .finished:
                island.attention()
                Sounds.play(.finished)
            case .failed:
                island.attention()
                Sounds.play(.failed)
            case .started:
                island.activity()
                Sounds.play(.started)
            }
            _ = session
        }
        model.attach()
        registerShortcuts()

        let nc = NotificationCenter.default
        nc.addObserver(forName: .jarvisRelocateIsland, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { island.relocate() }
        }
        nc.addObserver(forName: .jarvisDesktopOrb, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.desktopOrb?.sync() }
        }
        nc.addObserver(forName: .jarvisShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerShortcuts() }
        }
        hideTheOldTray()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        island?.attention()
        return false
    }

    private func registerShortcuts() {
        guard let island else { return }
        var bindings: [(Shortcut, () -> Void)] = []
        for action in ShortcutAction.allCases {
            guard let shortcut = action.shortcut else { continue }
            bindings.append((shortcut, { [weak self] in self?.perform(action, island: island) }))
        }
        HotKeyCenter.shared.register(bindings)
    }

    private func perform(_ action: ShortcutAction, island: IslandController) {
        switch action {
        case .toggleIsland: island.toggle()
        case .openChat, .goToAlert, .attachWindow: island.attention()
        case .jumpToTerminal: TerminalTarget.activate(session: model.selected)
        case .nextSession, .previousSession:
            let keys = model.sessions.map(\.key)
            guard !keys.isEmpty else { return }
            let i = keys.firstIndex(of: model.selectedKey ?? "") ?? -1
            let step = action == .nextSession ? 1 : -1
            model.selectedKey = keys[(i + step + keys.count) % keys.count]
            island.attention()
        case .mute: Prefs.soundOn.toggle()
        case .desktopOrb: desktopOrb?.toggle()
        case .nextSkin:
            let all = ["auto"] + OrbSkin.allCases.map(\.rawValue)
            let i = all.firstIndex(of: Prefs.skin) ?? 0
            Prefs.skin = all[(i + 1) % all.count]
            island.attention()
        case .talk: menuBar?.toggleVoice()
        }
    }

    private static func anotherCopyRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me }
    }

    /// The Python tray's menu-bar item would sit next to ours: it steps aside
    /// when it sees this file (desktop_client/jc_client/tray.py).
    private func hideTheOldTray() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".jarviscopilot-client/mac-app.running")
        FileManager.default.createFile(atPath: marker, contents: Data("\(ProcessInfo.processInfo.processIdentifier)".utf8))
    }

    func applicationWillTerminate(_ notification: Notification) {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".jarviscopilot-client/mac-app.running")
        try? FileManager.default.removeItem(atPath: marker)
    }
}
