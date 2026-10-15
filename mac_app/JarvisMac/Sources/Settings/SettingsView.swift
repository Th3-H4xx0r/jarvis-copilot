import AppKit
import SwiftUI

/// The Jarvis app's own settings: the island, sounds, the agents' hooks, the
/// shortcuts. (Keys for services and models live on the server: Jarvis
/// Settings on the web or the phone.)
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Jarvis Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AgentsSettings(model: model).tabItem { Label("Agents", systemImage: "terminal") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "waveform") }
            FlowSettings().tabItem { Label("Flow", systemImage: "text.bubble") }
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @State private var display = Prefs.display.rawValue
    @State private var hover = Prefs.openOnHover
    @State private var hideIdle = Prefs.hideWhenIdle
    @State private var sound = Prefs.soundOn
    @State private var volume = Prefs.volume
    @State private var skin = Prefs.skin
    @State private var login = Prefs.launchAtLogin
    @State private var desktop = Prefs.desktopOrb

    var body: some View {
        Form {
            Section("Island") {
                Picker("Show on", selection: $display) {
                    Text("The screen with the notch").tag("notch")
                    Text("The menu-bar screen").tag("menuBar")
                    Text("Wherever the pointer is").tag("followMouse")
                    ForEach(NSScreen.screens, id: \.self) { s in
                        if let id = IslandController.uuid(of: s) {
                            Text(s.localizedName).tag("display:\(id)")
                        }
                    }
                }
                .onChange(of: display) { _, v in
                    Prefs.display = IslandDisplayChoice(rawValue: v)
                    NotificationCenter.default.post(name: .jarvisRelocateIsland, object: nil)
                }
                Toggle("Open when the pointer reaches it", isOn: $hover)
                    .onChange(of: hover) { _, v in Prefs.openOnHover = v }
                Toggle("Hide it when no agent is running", isOn: $hideIdle)
                    .onChange(of: hideIdle) { _, v in Prefs.hideWhenIdle = v }
            }
            Section("Orb") {
                Picker("Look", selection: $skin) {
                    Text("Automatic (seasons)").tag("auto")
                    ForEach(OrbSkin.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
                .onChange(of: skin) { _, v in Prefs.skin = v }
                Toggle("Keep an orb on the desktop", isOn: $desktop)
                    .onChange(of: desktop) { _, v in
                        Prefs.desktopOrb = v
                        NotificationCenter.default.post(name: .jarvisDesktopOrb, object: nil)
                    }
            }
            Section("Sound") {
                Toggle("Play sounds", isOn: $sound).onChange(of: sound) { _, v in Prefs.soundOn = v }
                Slider(value: $volume, in: 0...1) { Text("Volume") }
                    .onChange(of: volume) { _, v in Prefs.volume = v; Sounds.play(.finished) }
                Button("Open the sounds folder") {
                    try? FileManager.default.createDirectory(at: Sounds.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Sounds.folder)
                }
                Text("Drop needs-you, finished, failed, started or decided (.wav, .aiff, .m4a, .mp3) there to replace a sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open Jarvis at login", isOn: $login).onChange(of: login) { _, v in Prefs.launchAtLogin = v }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentsSettings: View {
    let model: AppModel
    @State private var status: String = "Checking…"
    @State private var installed = false
    @State private var busy = false
    @State private var diff = ""

    var body: some View {
        Form {
            Section("Claude Code") {
                HStack {
                    Text(status)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("Jarvis follows every Claude Code session through its hooks — in Terminal, iTerm, VS Code or tmux — and adds a status line that reports your plan's limits (the one you had keeps running underneath). Your settings.json is backed up first.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? "Update hooks" : "Install hooks") { install() }
                    Button("Show the change") { run("preview") }
                    if installed { Button("Remove") { run("uninstall") } }
                }
                if !diff.isEmpty {
                    ScrollView { Text(diff).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 160)
                }
            }
            OtherAgentsSection(model: model)
            Section("From the phone") {
                LabeledContent("Approvals and questions", value: model.approvalsOn ? "On" : "Off")
                LabeledContent("Instructions to Terminal sessions", value: model.instructionsOn ? "On" : "Off")
                Text("Turn these on in Jarvis → Code Master settings (web or phone). While approvals are on, a waiting command shows in the island and on the phone; the terminal asks if nobody answers within two minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { run("status") }
    }

    /// Preview, show exactly what would be written, and write only that.
    private func install() {
        busy = true
        HookInstallConfirm.run(model: model, agent: "claude", name: "Claude Code") { message in
            busy = false
            if let message { status = message }
            run("status")
        }
    }

    private func run(_ action: String) {
        busy = true
        model.hooks(action) { reply in
            busy = false
            if action == "preview" {
                diff = J.s(reply["diff"], "Already up to date.")
                return
            }
            let st = J.obj(reply["status"])
            if !J.b(reply["ok"]) {
                status = J.s(reply["error"], "Jarvis isn't running on this Mac.")
                return
            }
            installed = J.b(st["installed"]) || (action == "install")
            status = installed ? (J.b(st["outdated"]) ? "Installed — an update is available" : "Installed")
                               : "Not installed"
            if action != "status" { run("status") }
        }
    }
}

private struct ShortcutsSettings: View {
    @State private var values: [String: String] = Dictionary(uniqueKeysWithValues:
        ShortcutAction.allCases.map { ($0.rawValue, $0.shortcut?.string ?? "") })

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        TextField("off", text: Binding(get: { values[action.rawValue] ?? "" },
                                                       set: { values[action.rawValue] = $0 }))
                            .frame(width: 150)
                            .onSubmit { save(action) }
                        Text(Shortcut(string: values[action.rawValue] ?? "")?.display ?? "—")
                            .frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Type a shortcut like ctrl+opt+space or cmd+shift+j and press Return. Empty turns it off.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func save(_ action: ShortcutAction) {
        let raw = (values[action.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        action.shortcut = raw.isEmpty ? nil : Shortcut(string: raw)
        values[action.rawValue] = action.shortcut?.string ?? ""
        NotificationCenter.default.post(name: .jarvisShortcutsChanged, object: nil)
    }
}

extension Notification.Name {
    static let jarvisRelocateIsland = Notification.Name("jarvis.relocateIsland")
    static let jarvisDesktopOrb = Notification.Name("jarvis.desktopOrb")
    static let jarvisShortcutsChanged = Notification.Name("jarvis.shortcutsChanged")
}

/// Codex, Gemini, Copilot and the rest: each keeps its hooks in its own file
/// (desktop_client/jc_client/hook_install.py OTHER_AGENTS).
private struct OtherAgentsSection: View {
    let model: AppModel
    @State private var installed: [String: Bool] = [:]
    @State private var errors: [String: String] = [:]
    @State private var busy: String?

    static let agents: [(id: String, name: String)] = [
        ("codex", "Codex"), ("gemini", "Gemini CLI"), ("copilot", "GitHub Copilot CLI"),
        ("antigravity", "Antigravity"), ("opencode", "OpenCode"), ("amp", "Amp"), ("muse", "Muse Code"),
    ]

    var body: some View {
        Section("Other agents") {
            ForEach(Self.agents, id: \.id) { agent in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                        if let err = errors[agent.id] {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if busy == agent.id { ProgressView().controlSize(.small) }
                    if installed[agent.id] == true {
                        Button("Remove") { run("uninstall", agent.id) }
                    } else {
                        Button("Install") {
                            busy = agent.id
                            HookInstallConfirm.run(model: model, agent: agent.id, name: agent.name) { message in
                                busy = nil
                                errors[agent.id] = message
                                refresh()
                            }
                        }
                    }
                }
            }
            Text("Each agent keeps its own hook file; Jarvis only adds its entries and backs the file up first. Codex asks you once to trust new hooks.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        model.hooks("status", agent: "all") { reply in
            let all = J.obj(reply["agents"])
            for (id, _) in Self.agents {
                installed[id] = J.b(J.obj(all[id])["installed"])
            }
        }
    }

    private func run(_ action: String, _ id: String) {
        busy = id
        model.hooks(action, agent: id) { reply in
            busy = nil
            errors[id] = J.b(reply["ok"]) ? nil : J.s(reply["error"], "Jarvis isn't running on this Mac.")
            refresh()
        }
    }
}

/// The hooks are written only after you've seen the change: preview, show the
/// diff, then install with the preview's token (jc-client refuses a stale one).
@MainActor
enum HookInstallConfirm {
    /// `done(nil)` when installed or nothing to do; `done(message)` otherwise.
    static func run(model: AppModel, agent: String, name: String, done: @escaping (String?) -> Void) {
        model.hooks("preview", agent: agent) { reply in
            guard J.b(reply["ok"]) else {
                done(J.s(reply["error"], "Jarvis isn't running on this Mac."))
                return
            }
            let diff = J.s(reply["diff"])
            guard !diff.isEmpty else { done(nil); return }
            let alert = NSAlert()
            alert.messageText = "Add Jarvis's hooks to \(name)?"
            alert.informativeText = "This is the whole change. The file is backed up first."
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
            text.string = diff
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Write these changes")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { done("Not installed."); return }
            model.hooks("install", agent: agent, token: J.s(reply["token"])) { r in
                done(J.b(r["ok"]) ? nil : J.s(r["error"], "Couldn't install."))
            }
        }
    }
}
