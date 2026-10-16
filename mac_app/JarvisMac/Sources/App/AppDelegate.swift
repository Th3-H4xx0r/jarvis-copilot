import AppKit

/// Puts the app together: the link to jc-client, the island (Jarvis on the Mac
/// lives only in the notch — its menu pops from a right-click), the desktop orb
/// and the global shortcuts. Under XCTest it starts nothing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var menu: JarvisMenu?
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
        let menu = JarvisMenu(model: model, island: island)
        menu.onSettings = { [weak self] in self.map { SettingsWindow.show(model: $0.model) } }
        menu.onDemo = { [weak self] in self.map { DemoEngine.run(model: $0.model, island: island) } }
        menu.onRecap = { [weak self] in self.map { RecapWindow.show(model: $0.model) } }
        menu.onFlow = { FlowWindow.show() }
        menu.onNotes = { FlowWindow.show(.notes) }
        self.menu = menu
        island.voicePanel = { [weak menu] in menu?.makeVoicePanel(island: true) }
        island.voiceMiniPanel = { [weak menu] in menu?.makeVoiceMiniPanel() ?? menu?.makeVoicePanel(island: true) }
        island.ui.setVoiceOrbHidden = { [weak menu] hidden in
            VoicePanelOrb.setHidden(hidden, on: menu?.voicePanelClass())
        }
        island.onMenu = { [weak menu] view, point in menu?.popUp(in: view, at: point) }
        Prefs.openAtLoginByDefault()
        desktopOrb = DesktopOrbController(model: model, island: island)

        model.onMoment = { moment, session in
            switch moment {
            case .needsYou:
                island.open(.agents)
                Sounds.play(.needsYou)
            case .finished:
                island.attention()
                Sounds.play(.finished)
            case .failed:
                island.attention()
                Sounds.play(.failed)
            case .started:
                if Prefs.showWhileWorking { island.activity() }
                Sounds.play(.started)
            }
            _ = session
        }
        model.attach()
        registerShortcuts()
        MusicController.shared.start()
        WindowContext.startWatching()
        startVoiceFeatures(island: island)
        model.onIsland = { [weak self] tab, text in
            guard let self else { return }
            if tab == "recap" { RecapWindow.show(model: self.model); return }
            if let text, !text.isEmpty { MacChatStore.shared.draft = text }
            island.open(IslandTab(rawValue: tab) ?? .agents)
        }

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
        var bindings: [HotKeyCenter.Binding] = []
        for action in ShortcutAction.allCases {
            guard let shortcut = action.shortcut else { continue }
            if action.holds {
                bindings.append(HotKeyCenter.Binding(
                    shortcut: shortcut,
                    pressed: { [weak self] in self?.hold(action, down: true, island: island) },
                    released: { [weak self] in self?.hold(action, down: false, island: island) }))
            } else {
                bindings.append(HotKeyCenter.Binding(shortcut: shortcut,
                                                     pressed: { [weak self] in self?.perform(action, island: island) }))
            }
        }
        HotKeyCenter.shared.register(bindings)
    }

    /// A held shortcut. Talk to Jarvis: the island opens on Voice and Jarvis
    /// listens while the key is down; letting go sends what you said. The
    /// island: shown while the key is down.
    private func hold(_ action: ShortcutAction, down: Bool, island: IslandController) {
        switch action {
        case .talk:
            if down {
                VoicePanelTalk.begin(on: menu?.voicePanelClass()) { [weak island] in
                    island?.openVoice(mini: true)
                    ScreenGlow.shared.show(on: island?.currentScreen)
                }
            } else {
                VoicePanelTalk.ended(on: menu?.voicePanelClass())
            }
        case .toggleIsland:
            if down { if !island.isExpanded { island.toggle() } } else { island.close() }
        default:
            if down { perform(action, island: island) }
        }
    }

    private func perform(_ action: ShortcutAction, island: IslandController) {
        switch action {
        case .toggleIsland: island.toggle()
        case .openChat: island.open(.chat, reason: .typing)
        case .goToAlert: island.open(.agents)
        case .attachWindow:
            // The island never takes focus from the app you're in, so that app is
            // still frontmost here.
            let front = NSWorkspace.shared.frontmostApplication
            let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? WindowContext.lastApp : front
            MacChatStore.shared.captureWindow(from: app)
            island.open(.chat, reason: .typing)
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
        case .talk: island.toggleVoice()
        case .recordCall:
            if !NoteTaker.shared.isRecording { FlowWindow.show(.notes) }
            NoteTaker.shared.toggle()
        }
    }

    /// "Hey Jarvis", Flow dictation and the note-taker. The first two only listen
    /// when turned on in Settings; the note-taker only records on Record.
    private func startVoiceFeatures(island: IslandController) {
        let wake = WakeWord.shared
        wake.onWake = { [weak island] in island?.openVoice() }
        wake.interaction = { [weak self, weak island] in
            let pending = !(self?.model.pending.isEmpty ?? true)
            guard let island, island.isExpanded else { return (pending, false) }
            return (pending, island.ui.pinned || island.ui.tab == .chat)
        }
        wake.start()
        FlowDictation.shared.start()
        // Push to talk: hold the key (Settings → Voice), the small island opens
        // and Jarvis listens; let go and it answers; the island folds after.
        let talk = TalkKeyWatcher.shared
        talk.onStart = { [weak self, weak island] in
            VoicePanelTalk.begin(on: self?.menu?.voicePanelClass()) {
                island?.openVoice(mini: true)
                ScreenGlow.shared.show(on: island?.currentScreen)
            }
        }
        // The glow goes back up when the island folds (answer done, clicked away).
        island.onFolded = { ScreenGlow.shared.hide() }
        ScreenGlow.shared.prepare()
        talk.onSend = { [weak self] in VoicePanelTalk.ended(on: self?.menu?.voicePanelClass()) }
        talk.sync()
        // Load the voice panel's dylib and its voice store ahead of the first
        // press (it stalled the first push to talk ~80 ms), while nothing moves.
        if Prefs.talkKey != nil || ShortcutAction.talk.holds {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                _ = self?.menu?.makeVoiceMiniPanel()
            }
        }
        NotificationCenter.default.addObserver(forName: VoicePanelTalk.doneNotification, object: nil, queue: .main) { [weak island] _ in
            MainActor.assumeIsolated { island?.talkDone() }
        }
        NoteTaker.shared.load()
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
        NoteTaker.shared.shutdown()
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".jarviscopilot-client/mac-app.running")
        try? FileManager.default.removeItem(atPath: marker)
    }
}
