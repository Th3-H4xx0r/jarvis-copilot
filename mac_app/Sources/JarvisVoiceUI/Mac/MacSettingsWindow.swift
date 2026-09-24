import AppKit
import SwiftUI
import WebKit

/// Jarvis Settings on the Mac: one window with a sidebar, everything the phone's
/// Settings reach and the panel's pickers hold.
///
/// "On this Mac" is native, on the same stores the phone and the panel use
/// (voice, Live, speech, voices). "Server" is the server's own settings, one
/// section per item, in the embedded page the phone's Server settings uses —
/// the source of truth for models, providers, plugins and the rest, so these
/// never drift from the web.
@MainActor
enum MacSettingsWindow {
    private static var window: NSWindow?

    static func show(_ section: MacSettingsSection? = nil) {
        if let section { MacSettingsSelection.shared.section = section }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: MacSettingsView())
        // The window keeps the size it is given and the user's resizes; the
        // view only sets the floor.
        host.sizingOptions = [.minSize]
        let made = NSWindow(contentViewController: host)
        made.title = "Jarvis Settings"
        made.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        made.titlebarAppearsTransparent = true
        made.isReleasedWhenClosed = false
        made.appearance = NSAppearance(named: .darkAqua)
        made.setContentSize(NSSize(width: 920, height: 640))
        made.center()
        made.setFrameAutosaveName("JarvisSettings")
        window = made
        NSApp.activate(ignoringOtherApps: true)
        made.makeKeyAndOrderFront(nil)
    }
}

/// Which section the window shows — kept outside the view so a second `show`
/// (the tray's menu item while it is open) can move it.
@MainActor
@Observable
final class MacSettingsSelection {
    static let shared = MacSettingsSelection()
    var section: MacSettingsSection = .voice
}

enum MacSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case voice, live, speech, voices
    case conversation, providers, appearance, preferences, plugins, integrations, system

    var id: String { rawValue }

    static let onThisMac: [MacSettingsSection] = [.voice, .live, .speech, .voices]
    static let server: [MacSettingsSection] = [.conversation, .providers, .appearance, .preferences,
                                                .plugins, .integrations, .system]

    var title: String {
        switch self {
        case .voice: return "Voice"
        case .live: return "Live"
        case .speech: return "Speech"
        case .voices: return "Voices"
        case .conversation: return "Conversation"
        case .providers: return "Models & providers"
        case .appearance: return "Appearance"
        case .preferences: return "Preferences"
        case .plugins: return "Plugins"
        case .integrations: return "Integrations"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .voice: return "waveform"
        case .live: return "dot.radiowaves.left.and.right"
        case .speech: return "text.bubble"
        case .voices: return "person.2.fill"
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .providers: return "cpu"
        case .appearance: return "paintbrush.fill"
        case .preferences: return "slider.horizontal.3"
        case .plugins: return "puzzlepiece.extension.fill"
        case .integrations: return "square.grid.2x2.fill"
        case .system: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .voice: return Color(jcHex: 0x2F8CFF)
        case .live: return Color(jcHex: 0xFF4D5A)
        case .speech: return Color(jcHex: 0x9B6BFF)
        case .voices: return Color(jcHex: 0x2FBF8F)
        case .conversation: return Color(jcHex: 0x19A7C9)
        case .providers: return Color(jcHex: 0xF28C28)
        case .appearance: return Color(jcHex: 0xE0529C)
        case .preferences: return Color(jcHex: 0x7C8494)
        case .plugins: return Color(jcHex: 0x3FAE4A)
        case .integrations: return Color(jcHex: 0x5B6CF0)
        case .system: return Color(jcHex: 0x6B7280)
        }
    }

    /// The server's settings section this item opens, for the server items.
    var webSection: String? { MacSettingsSection.server.contains(self) ? rawValue : nil }
}

struct MacSettingsView: View {
    @State private var selection = MainActor.assumeIsolated { MacSettingsSelection.shared }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(selection.section) },
                                    set: { if let value = $0 { selection.section = value } })) {
                Section("On this Mac") {
                    ForEach(MacSettingsSection.onThisMac) { row($0) }
                }
                Section("Server") {
                    ForEach(MacSettingsSection.server) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail(selection.section)
                .navigationTitle(selection.section.title)
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
    }

    private func row(_ section: MacSettingsSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(section.tint.gradient))
        }
        .tag(section)
    }

    @ViewBuilder
    private func detail(_ section: MacSettingsSection) -> some View {
        switch section {
        case .voice: MacVoiceSettingsPane()
        case .live: MacLiveSettingsPane()
        case .speech: MacSpeechSettingsPane()
        case .voices: MacVoicesPane()
        default: MacServerSettingsPane(section: section.webSection ?? "conversation")
        }
    }
}

// MARK: - Voice

/// The panel's two pickers (conversation and model, then the chat the voice
/// talks in), as a form: the same rows, so the two can never disagree.
private struct MacVoiceSettingsPane: View {
    @State private var store = MainActor.assumeIsolated { VoiceStore.shared }
    @State private var models = MacModelPicker()
    @State private var sessions = MacSessionPicker()

    var body: some View {
        Form {
            if store.isActive {
                Section { Text("End the conversation to change these.").foregroundStyle(JcTheme.muted) }
            }
            MacPickerRowsForm(rows: models.rows(store: store))
            MacPickerRowsForm(rows: [.header("Voice session")] + sessions.rows { store.sessionTargetChanged() })
        }
        .formStyle(.grouped)
        .task {
            await models.load()
            await sessions.load()
        }
    }
}

/// `PickerRow`s as form sections: a header starts a section, a choice is a
/// segmented control, an item is a checkable row.
private struct MacPickerRowsForm: View {
    let rows: [PickerRow]

    private var sections: [(title: String, rows: [PickerRow])] {
        var out: [(title: String, rows: [PickerRow])] = [("", [])]
        for row in rows {
            if row.kind == .header {
                if out[out.count - 1].rows.isEmpty { out[out.count - 1].title = row.title }
                else { out.append((row.title, [])) }
            } else {
                out[out.count - 1].rows.append(row)
            }
        }
        return out.filter { !$0.rows.isEmpty || !$0.title.isEmpty }
    }

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(section.rows) { row in
                    switch row.kind {
                    case .choice: choice(row)
                    case .item: item(row)
                    case .header: EmptyView()
                    }
                }
            } header: {
                if !section.title.isEmpty { Text(section.title) }
            }
        }
    }

    private func choice(_ row: PickerRow) -> some View {
        Picker(row.title, selection: Binding(
            get: { row.choices.first(where: \.selected)?.title ?? "" },
            set: { title in row.choices.first { $0.title == title }?.action() })) {
            ForEach(row.choices) { choice in
                Text(choice.title).tag(choice.title)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!row.choices.contains(where: \.enabled))
    }

    private func item(_ row: PickerRow) -> some View {
        Button(action: row.action) {
            HStack {
                Text(row.title).foregroundStyle(JcTheme.text)
                Spacer()
                if row.checked {
                    Image(systemName: "checkmark").foregroundStyle(JcTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live

private struct MacLiveSettingsPane: View {
    @State private var store = MainActor.assumeIsolated { LiveStore.shared }

    private func binding<V>(_ path: WritableKeyPath<LiveConfig, V>) -> Binding<V> {
        Binding(get: { store.config[keyPath: path] }, set: { value in
            var updated = store.config
            updated[keyPath: path] = value
            Task { await store.save(updated) }
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Live capture", isOn: binding(\.enabled))
                Picker("Replies", selection: binding(\.replyMode)) {
                    Text("Text").tag("text")
                    Text("Spoken").tag("spoken")
                }
                TextField("Primary language", text: binding(\.primaryLanguage))
            } footer: {
                Text("The language lines are translated into, and the one Live expects first.")
            }
            Section("While it listens") {
                Toggle("Monitor", isOn: binding(\.monitor))
                Toggle("Fact-check", isOn: binding(\.factCheck))
                Toggle("Translate", isOn: binding(\.translate))
                Toggle("Memory extraction", isOn: binding(\.memoryExtraction))
                Toggle("Artifacts at the end", isOn: binding(\.artifacts))
                Stepper("Window: \(store.config.windowSeconds) s", value: binding(\.windowSeconds),
                        in: 10...3600, step: 10)
                Stepper("Minimum new words: \(store.config.minWindowWords)", value: binding(\.minWindowWords),
                        in: 0...500, step: 5)
                Stepper("Fact-check reads \(store.config.factCheckTokens) tokens", value: binding(\.factCheckTokens),
                        in: 100...20000, step: 100)
            }
            Section {
                Picker("Voice identity", selection: binding(\.speakerSplit)) {
                    Text("Voiceprints (WeSpeaker ResNet34)").tag("voiceprint")
                    Text("Soniox splits, voiceprints name").tag("engine")
                }
            } footer: {
                Text("With Soniox, its speaker labels split the conversation and voiceprints only name each speaker, from all of their audio together. Applies while Live is transcribed by Soniox.")
            }
            Section("Sessions") {
                VStack(alignment: .leading) {
                    Text("New session at \(Int(store.config.sessionRolloverFraction * 100))% of the model's context")
                    Slider(value: binding(\.sessionRolloverFraction), in: 0.05...1.0)
                }
                TextField("Model (empty follows the app's)", text: binding(\.model))
            }
            if !store.error.isEmpty {
                Section { Text(store.error).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .task { await store.loadConfig() }
    }
}

// MARK: - Speech

private struct MacSpeechSettingsPane: View {
    @State private var speech = MainActor.assumeIsolated { SpeechEngineStore.shared }
    @State private var keyDraft = ""
    @State private var hintsDraft = ""
    @State private var wordsDraft = ""

    private var soniox: SpeechSoniox { speech.settings.soniox }

    private func setSoniox<V>(_ path: WritableKeyPath<SpeechSoniox, V>, _ value: V, _ key: String) {
        Task { await speech.setSoniox(path, value, key: key) }
    }

    private func engineRow(_ title: String, surface: String, value: String, device: Bool) -> some View {
        Picker(title, selection: Binding(get: { value },
                                         set: { new in Task { await speech.setSurface(surface, to: new) } })) {
            if device { Text("On the device").tag(SpeechSettings.edge) }
            ForEach(speech.settings.engines.filter { surface != "live" || $0.streams }) { engine in
                Text(engine.name == "local" ? "The server's own model" : engine.label)
                    .tag(engine.name)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                engineRow("Voice (browser, Pod)", surface: "voice", value: speech.settings.voice, device: false)
                engineRow("Live", surface: "live", value: speech.settings.live, device: true)
                engineRow("Uploads & voice notes", surface: "upload", value: speech.settings.upload, device: false)
            } header: {
                Text("Who turns speech into text")
            } footer: {
                Text("Phones and Macs transcribe Voice themselves; this is for audio that reaches the server.")
            }
            Section("Soniox key") {
                LabeledContent("Saved key", value: speech.settings.keySet ? speech.settings.keyHint : "None")
                SecureField("Paste a new key", text: $keyDraft)
                HStack {
                    Button("Save") {
                        let key = keyDraft
                        Task { if await speech.saveKey(key) { keyDraft = "" } }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test") { Task { await speech.test() } }
                        .disabled(speech.testing)
                    Spacer()
                    Button("Remove", role: .destructive) { Task { _ = await speech.saveKey("") } }
                        .disabled(!speech.settings.keySet)
                }
                if !speech.testMessage.isEmpty {
                    Text((speech.testPassed == true ? "Works — " : "Failed — ") + speech.testMessage)
                        .foregroundStyle(speech.testPassed == true ? Color.green : Color.orange)
                }
            }
            Section("Soniox") {
                Toggle("Speaker labels", isOn: Binding(get: { soniox.speakerLabels },
                                                       set: { setSoniox(\.speakerLabels, $0, "speaker_labels") }))
                Toggle("Language identification", isOn: Binding(get: { soniox.languageID },
                                                                 set: { setSoniox(\.languageID, $0, "language_id") }))
                TextField("Languages (codes, comma separated — empty hears any)", text: $hintsDraft)
                    .onSubmit { setSoniox(\.languageHints, Self.list(hintsDraft), "language_hints") }
                TextField("Custom words (comma separated)", text: $wordsDraft)
                    .onSubmit { setSoniox(\.customWords, Self.list(wordsDraft), "custom_words") }
                Stepper("Close a quiet Live stream after \(soniox.liveQuietCloseS) s",
                        value: Binding(get: { soniox.liveQuietCloseS },
                                       set: { setSoniox(\.liveQuietCloseS, $0, "live_quiet_close_s") }),
                        in: 10...600, step: 10)
            }
            Section("Advanced — endpoint tuning") {
                Stepper("Latency level \(soniox.endpointLatencyLevel)",
                        value: Binding(get: { soniox.endpointLatencyLevel },
                                       set: { setSoniox(\.endpointLatencyLevel, $0, "endpoint_latency_level") }),
                        in: 0...3)
                VStack(alignment: .leading) {
                    Text("Sensitivity \(String(format: "%.2f", soniox.endpointSensitivity))")
                    Slider(value: Binding(get: { soniox.endpointSensitivity },
                                          set: { setSoniox(\.endpointSensitivity, $0, "endpoint_sensitivity") }),
                           in: 0...1)
                }
                Stepper("Longest wait for the end of a line: \(soniox.maxEndpointDelayMs) ms",
                        value: Binding(get: { soniox.maxEndpointDelayMs },
                                       set: { setSoniox(\.maxEndpointDelayMs, $0, "max_endpoint_delay_ms") }),
                        in: 500...5000, step: 100)
            }
            Section("Usage") {
                LabeledContent("Today", value: Self.duration(speech.settings.todaySeconds))
                LabeledContent("This month", value: Self.duration(speech.settings.monthSeconds)
                               + String(format: " · about $%.2f", speech.settings.monthUSD))
            }
            if !speech.error.isEmpty {
                Section { Text(speech.error).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .task {
            await speech.load()
            hintsDraft = soniox.languageHints.joined(separator: ", ")
            wordsDraft = soniox.customWords.joined(separator: ", ")
        }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 3600 ? "\(seconds / 60) min" : String(format: "%.1f h", Double(seconds) / 3600)
    }
}

// MARK: - Voices

/// Every voice Live knows, and — opened — everything it has said, a page at a time.
private struct MacVoicesPane: View {
    @State private var store = MainActor.assumeIsolated { LiveStore.shared }

    var body: some View {
        NavigationStack {
            List {
                if store.speakers.isEmpty {
                    Text("No voices yet. Record a conversation and the voices in it appear here.")
                        .foregroundStyle(JcTheme.muted)
                }
                ForEach(store.speakers) { speaker in
                    NavigationLink {
                        MacVoiceHistoryView(name: speaker.displayName,
                                            history: store.voiceHistory(speakerID: speaker.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(speaker.displayName).font(.system(size: 13, weight: .semibold))
                            Text("\(speaker.segmentCount) lines · \(max(1, speaker.speechMs / 60000)) min of speech")
                                .font(.system(size: 11))
                                .foregroundStyle(JcTheme.muted)
                            if let sample = speaker.samples.first {
                                Text("“\(sample)”").font(.system(size: 12)).foregroundStyle(JcTheme.text.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .task { await store.loadSpeakers() }
        }
    }
}

private struct MacVoiceHistoryView: View {
    let name: String
    @State var history: LiveVoiceHistory

    var body: some View {
        List {
            Section {
                ForEach(Array(history.lines.enumerated()), id: \.element.id) { index, line in
                    if index == 0 || history.lines[index - 1].sessionID != line.sessionID {
                        Text(line.sessionTitle.isEmpty ? "Live session" : line.sessionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(JcTheme.muted)
                            .padding(.top, 8)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                        Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                        if let translation = line.translation {
                            Text(translation).font(.system(size: 12).italic())
                                .foregroundStyle(JcTheme.text.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 2)
                    .onAppear {
                        if index == history.lines.count - 1 { Task { await history.loadMore() } }
                    }
                }
            } header: {
                Text("\(history.total) lines, newest first")
            }
            if !history.error.isEmpty {
                Button("Retry — \(history.error)") { Task { await history.loadMore() } }
            } else if history.done {
                Text(history.lines.isEmpty ? "Nothing heard from this voice yet."
                                           : "That is everything this voice has said.")
                    .foregroundStyle(JcTheme.muted)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(name)
        .task { if history.lines.isEmpty { await history.loadMore() } }
    }
}

// MARK: - Server

/// One of the server's own settings sections, in the page the phone embeds:
/// through the client's loopback proxy (which holds the pinned certificate and
/// the session), with the page's embed mode on so it shows the pane alone.
private struct MacServerSettingsPane: NSViewRepresentable {
    let section: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let embed = WKUserScript(source: "window.JarvisCopilotMobile = window.JarvisCopilotMobile || {};",
                                 injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(embed)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        load(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url.map({ !$0.absoluteString.contains("section=\(section)") }) ?? true { load(view) }
    }

    private func load(_ view: WKWebView) {
        guard let base = ProxyCredentials().baseURL,
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            view.loadHTMLString("<body style='background:#111;color:#999;font:13px -apple-system;padding:24px'>"
                                + "Open the Jarvis panel once so this window can reach the server.</body>",
                                baseURL: nil)
            return
        }
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "panel", value: "settings"),
                            URLQueryItem(name: "section", value: section)]
        if let url = parts.url { view.load(URLRequest(url: url)) }
    }
}

/// The gear in the panels' top bars.
struct MacSettingsButton: View {
    var body: some View {
        Button {
            MacSettingsWindow.show()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.accent)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jarvis Settings")
        .accessibilityLabel("Jarvis Settings")
    }
}
