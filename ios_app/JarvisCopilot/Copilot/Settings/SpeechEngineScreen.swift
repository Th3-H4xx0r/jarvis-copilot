import SwiftUI

/// Settings → Speech engine: which engine turns speech into text for Voice, Live
/// and uploads, and every Soniox option. The same server settings the web's
/// Settings → Speech block edits; each change is saved as it is made.
struct SpeechEngineScreen: View {
    @State private var store = SpeechEngineStore.shared
    @State private var keyDraft = ""
    @State private var newWord = ""

    private static let quietChoices = [30, 60, 120, 300, 600]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                surface("voice", title: "Voice",
                        note: "Phone and Mac voice when Transcription is Server, the web Voice tab, "
                            + "and the Jarvis Pod.")
                surface("live", title: "Live",
                        note: "Who hears Live recordings: this phone itself, or a server engine that "
                            + "streams every language at once, with translation.")
                surface("upload", title: "Uploads",
                        note: "The web chat mic, and voice notes from Telegram and Discord.")
                soniox
                if !store.error.isEmpty {
                    Text(store.error)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .jcScreen("Speech engine")
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    // MARK: - Engine per surface

    private func surface(_ name: String, title: String, note: String) -> some View {
        let s = store.settings
        let options: [(name: String, label: String, available: Bool, reason: String)] =
            name == "live"
            ? [(SpeechSettings.edge, s.label(for: SpeechSettings.edge), true, "")]
              + s.streamingEngines.map { ($0.name, $0.label, $0.available, $0.reason) }
            : s.engines.map { ($0.name, $0.label, $0.available, $0.reason) }
        let current = s.surface(name)
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel(title)
            GlassGroup {
                ForEach(Array(options.enumerated()), id: \.element.name) { index, option in
                    LiveRadioRow(title: option.label,
                                 subtitle: option.available || option.name == current ? nil : option.reason,
                                 selected: option.name == current,
                                 last: index == options.count - 1,
                                 action: { Task { await store.setSurface(name, to: option.name) } })
                        .disabled(!option.available && option.name != current)
                        .opacity(option.available || option.name == current ? 1 : 0.5)
                }
            }
            LiveSettingsNote(note)
        }
    }

    // MARK: - Soniox

    private var soniox: some View {
        let s = store.settings.soniox
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Soniox")
                GlassGroup { key }
                LiveSettingsNote("Soniox bills about $0.12 an hour while a stream is open. Audio "
                               + "goes to Soniox only for what you set to it above.")
            }
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Soniox options")
                GlassGroup {
                    NavigationLink {
                        SpeechLanguagesScreen(store: store)
                    } label: {
                        GlassRow(symbol: "globe", title: "Languages",
                                 subtitle: s.languageHints.isEmpty
                                    ? "Any language"
                                    : s.languageHints.map(store.settings.languageName).joined(separator: ", "),
                                 subtitleLineLimit: 2) { chevron }
                    }
                    .buttonStyle(.plain)
                    toggle("person.2.wave.2", "Speaker labels", "Tell voices apart in Live.",
                           \.speakerLabels, key: "speaker_labels")
                    toggle("character.bubble", "Language detection",
                           "Tag each line with the language it was spoken in.",
                           \.languageID, key: "language_id", last: true)
                }
            }
            words
            advanced
            Text(usageLine)
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 4)
        }
    }

    private var chevron: some View {
        JcIcon("chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(JcTheme.muted)
    }

    private var key: some View {
        let s = store.settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(s.keySet ? JcTheme.accent : JcTheme.muted.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(s.keySet ? "Key saved \(s.keyHint)" : "No key saved")
                    .font(JcText.body.weight(.semibold))
                    .foregroundStyle(JcTheme.text)
            }
            SecureField(s.keySet ? "Paste a new key to replace it" : "Paste your Soniox API key",
                        text: $keyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .jcFieldStyle()
            HStack(spacing: 10) {
                GlassButton(title: "Save", action: keyDraft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : {
                    let typed = keyDraft
                    keyDraft = ""
                    Task { await store.saveKey(typed) }
                })
                GlassButton(title: "Remove", ghost: true, action: s.keySet ? {
                    Task { await store.saveKey("") }
                } : nil)
                GlassButton(title: store.testing ? "Testing…" : "Test", ghost: true,
                            action: s.keySet && !store.testing ? { Task { await store.test() } } : nil)
            }
            if !store.testMessage.isEmpty {
                Text((store.testPassed == true ? "Works — " : "Failed — ") + store.testMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(store.testPassed == true ? JcTheme.accent : JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var words: some View {
        let list = store.settings.soniox.customWords
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Custom words")
            GlassGroup {
                ForEach(list, id: \.self) { word in
                    GlassRow(symbol: "textformat", title: word) {
                        Button {
                            Task { await store.setSoniox(\.customWords, list.filter { $0 != word },
                                                         key: "custom_words") }
                        } label: {
                            JcIcon("xmark.circle.fill").foregroundStyle(JcTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(word)")
                    }
                }
                HStack(spacing: 10) {
                    TextField("Add a name or term", text: $newWord)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(addWord)
                    GlassButton(title: "Add", ghost: true,
                                action: newWord.trimmingCharacters(in: .whitespaces).isEmpty ? nil : addWord)
                }
                .padding(14)
            }
            LiveSettingsNote("Names and terms Soniox should spell right, like Jarvis.")
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = store.settings.soniox.customWords
        newWord = ""
        guard !word.isEmpty, !list.contains(word) else { return }
        Task { await store.setSoniox(\.customWords, list + [word], key: "custom_words") }
    }

    private var advanced: some View {
        let s = store.settings.soniox
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Advanced")
            GlassGroup {
                GlassRow(symbol: "hare", title: "How fast a line closes",
                         subtitle: "Higher closes lines sooner, for a little accuracy.", subtitleLineLimit: 2) {
                    Stepper("\(s.endpointLatencyLevel)", value: Binding(
                        get: { s.endpointLatencyLevel },
                        set: { v in Task { await store.setSoniox(\.endpointLatencyLevel, v, key: "endpoint_latency_level") } }),
                            in: 0...3)
                        .fixedSize()
                }
                GlassRow(symbol: "waveform.path", title: "Line-end sensitivity",
                         subtitle: String(format: "%.1f — higher ends a line at shorter pauses.", s.endpointSensitivity),
                         subtitleLineLimit: 2) {
                    Stepper("", value: Binding(
                        get: { s.endpointSensitivity },
                        set: { v in
                            let rounded = (v * 10).rounded() / 10
                            Task { await store.setSoniox(\.endpointSensitivity, rounded, key: "endpoint_sensitivity") }
                        }), in: -1...1, step: 0.1)
                        .labelsHidden()
                }
                GlassRow(symbol: "timer", title: "Longest wait for a line end",
                         subtitle: "\(s.maxEndpointDelayMs) ms after speech stops.", subtitleLineLimit: 2) {
                    Stepper("", value: Binding(
                        get: { s.maxEndpointDelayMs },
                        set: { v in Task { await store.setSoniox(\.maxEndpointDelayMs, v, key: "max_endpoint_delay_ms") } }),
                            in: 500...3000, step: 100)
                        .labelsHidden()
                }
                GlassRow(symbol: "moon.zzz", title: "Close a Live stream after quiet",
                         subtitle: "It reopens on the next word; billing stops meanwhile.",
                         subtitleLineLimit: 2, last: true) {
                    Picker("", selection: Binding(
                        get: { Self.quietChoices.contains(s.liveQuietCloseS) ? s.liveQuietCloseS : 60 },
                        set: { v in Task { await store.setSoniox(\.liveQuietCloseS, v, key: "live_quiet_close_s") } })) {
                        ForEach(Self.quietChoices, id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .tint(JcTheme.accent)
                }
            }
        }
    }

    private func toggle(_ symbol: String, _ title: String, _ subtitle: String,
                        _ field: WritableKeyPath<SpeechSoniox, Bool>, key: String,
                        last: Bool = false) -> some View {
        GlassRow(symbol: symbol, title: title, subtitle: subtitle, subtitleLineLimit: 2, last: last) {
            Toggle("", isOn: Binding(get: { store.settings.soniox[keyPath: field] },
                                     set: { v in Task { await store.setSoniox(field, v, key: key) } }))
                .labelsHidden()
                .tint(JcTheme.accent)
        }
    }

    private var usageLine: String {
        let s = store.settings
        return "Soniox this month: \(Self.duration(s.monthSeconds)), about "
            + String(format: "$%.2f", s.monthUSD) + " · today \(Self.duration(s.todaySeconds))"
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 3600 ? "\(seconds / 60) min" : String(format: "%.1f h", Double(seconds) / 3600)
    }
}

/// Which languages Soniox should expect. None ticked means any language.
struct SpeechLanguagesScreen: View {
    let store: SpeechEngineStore
    @State private var query = ""

    private var shown: [SpeechLanguage] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.settings.languages.filter {
            needle.isEmpty || $0.name.lowercased().contains(needle) || $0.code.hasPrefix(needle)
        }
    }

    var body: some View {
        let hints = store.settings.soniox.languageHints
        let list = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassGroup {
                    ForEach(Array(list.enumerated()), id: \.element.code) { index, language in
                        let on = hints.contains(language.code)
                        GlassRow(symbol: on ? "checkmark.circle.fill" : "circle", title: language.name,
                                 last: index == list.count - 1,
                                 action: {
                                     let next = on ? hints.filter { $0 != language.code } : hints + [language.code]
                                     Task { await store.setSoniox(\.languageHints, next, key: "language_hints") }
                                 }) { EmptyView() }
                    }
                }
                LiveSettingsNote(hints.isEmpty
                    ? "None ticked: Soniox listens for any language."
                    : "Soniox favours these; it still hears others.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .jcScreen("Languages")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search languages")
    }
}
