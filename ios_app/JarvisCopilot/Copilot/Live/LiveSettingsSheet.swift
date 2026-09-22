import SwiftUI

/// Live Jarvis settings: the server's `live:` section, plus the two choices that
/// belong to this device.
///
/// The split matters and is visible in the sheet: the watcher section says the
/// settings are shared with the web client, and the "This device" section does not,
/// because a capture source is meaningless on another device (design §6).
struct LiveSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// A plain `let`, not `@State`: `LiveStore` is `@Observable`, so SwiftUI tracks
    /// the properties this body reads through the reference itself.
    let store: LiveStore

    /// Edited locally and PUT on change, so a toggle takes effect immediately
    /// rather than on a Save the user might not press.
    @State private var draft = LiveConfig()
    @State private var loaded = false

    private static let windowChoices = [30, 60, 120, 300, 600]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    device
                    watchers
                    window
                    replies
                    language
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
            .jcScreen("Live settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(JcText.body.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task {
            // The sheet can open before the screen's own load finished.
            if store.config == LiveConfig() { await store.loadConfig() }
            draft = store.config
            store.refreshSources()
            loaded = true
        }
    }

    // MARK: - This device

    private var device: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("This device")
            GlassGroup {
                GlassRow(symbol: "mic",
                         title: "Record on this phone",
                         subtitle: "Off makes this a viewer of whatever else is capturing.",
                         subtitleLineLimit: 3) {
                    Toggle("", isOn: Binding(get: { store.settings.captureHere },
                                             set: { store.settings.captureHere = $0 }))
                        .labelsHidden()
                        .tint(JcTheme.accent)
                }
                NavigationLink {
                    LiveCaptureSourceScreen(store: store)
                } label: {
                    GlassRow(symbol: "waveform",
                             title: "Microphone",
                             subtitle: store.activeSource.label,
                             last: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Watchers

    private var watchers: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Watchers")
            GlassGroup {
                toggleRow("eye", "Monitor",
                          "Reads a rolling window and can interject.",
                          get: { draft.monitor }, set: { draft.monitor = $0 })
                toggleRow("checkmark.seal", "Fact-check",
                          "On demand, from a segment's menu.",
                          get: { draft.factCheck }, set: { draft.factCheck = $0 })
                toggleRow("globe", "Translate",
                          "Automatic for anything not in the primary language.",
                          get: { draft.translate }, set: { draft.translate = $0 })
                toggleRow("brain", "Remember facts",
                          "Writes durable facts to your memory provider.",
                          get: { draft.memoryExtraction }, set: { draft.memoryExtraction = $0 })
                toggleRow("doc.text", "End-of-session artifacts",
                          "Summary, decisions and action items when a session ends.",
                          get: { draft.artifacts }, set: { draft.artifacts = $0 }, last: true)
            }
            Text("Shared with the web client — these are one setting, not one per device.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    // MARK: - Window

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Monitor window")
            GlassGroup {
                GlassRow(symbol: "timer", title: "Every") {
                    Picker("", selection: Binding(get: { draft.windowSeconds },
                                                  set: { draft.windowSeconds = $0; push() })) {
                        ForEach(Self.windowChoices, id: \.self) { seconds in
                            Text(Self.windowLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .tint(JcTheme.accent)
                }
                GlassRow(symbol: "text.word.spacing",
                         title: "Skip quiet windows",
                         subtitle: "Below \(draft.minWindowWords) new words the window is skipped, "
                                 + "so silence costs nothing.",
                         subtitleLineLimit: 3,
                         last: true) {
                    Stepper("", value: Binding(get: { draft.minWindowWords },
                                               set: { draft.minWindowWords = $0; push() }),
                            in: 0...200, step: 5)
                        .labelsHidden()
                }
            }
        }
    }

    private static func windowLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60) min"
    }

    // MARK: - Replies

    private var replies: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Replies")
            GlassGroup {
                GlassRow(symbol: "bubble.left",
                         title: "Spoken replies",
                         subtitle: "Read insights aloud in the phone's own voice.",
                         subtitleLineLimit: 3,
                         last: true) {
                    Toggle("", isOn: Binding(get: { draft.spokenReplies },
                                             set: { draft.replyMode = $0 ? "spoken" : "text"; push() }))
                        .labelsHidden()
                        .tint(JcTheme.accent)
                }
            }
        }
    }

    // MARK: - Language

    private var language: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Language")
            GlassGroup {
                GlassRow(symbol: "character.bubble", title: "Primary") {
                    // A free text field rather than a picker: the server's locale
                    // list is the authority and hardcoding one here would go stale.
                    TextField("en-US", text: Binding(get: { draft.primaryLanguage },
                                                     set: { draft.primaryLanguage = $0 }))
                        .multilineTextAlignment(.trailing)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 120)
                        .onSubmit { push() }
                }
                GlassRow(symbol: "person.wave.2",
                         title: "Voice model",
                         subtitle: draft.embedModel.isEmpty
                            ? "The server hasn't reported one yet."
                            : draft.embedModel,
                         subtitleLineLimit: 2,
                         last: true) {
                    // Read-only on purpose: the embedding-model id is the interlock
                    // of design §5.3, and a client that edited it could silently
                    // corrupt speaker identity across every device.
                    JcIcon("lock", size: 13).foregroundStyle(JcTheme.muted)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.chatSessionID.isEmpty {
                Text("This conversation also appears in Chats, so you can ask about it later.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
            }
            if !store.error.isEmpty {
                Text(store.error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Plumbing

    private func toggleRow(_ symbol: String, _ title: String, _ subtitle: String,
                           get: @escaping () -> Bool, set: @escaping (Bool) -> Void,
                           last: Bool = false) -> some View {
        GlassRow(symbol: symbol, title: title, subtitle: subtitle,
                 subtitleLineLimit: 3, last: last) {
            Toggle("", isOn: Binding(get: get, set: { set($0); push() }))
                .labelsHidden()
                .tint(JcTheme.accent)
        }
    }

    /// PUT the whole config. Guarded on `loaded` so the `.task`'s own assignment of
    /// `draft` cannot write the defaults back over what the server just sent.
    private func push() {
        guard loaded else { return }
        let payload = draft
        Task { await store.save(payload) }
    }
}

/// The capture-source picker: local audio routes, then any Jarvis wearable that
/// advertises a microphone.
struct LiveCaptureSourceScreen: View {
    let store: LiveStore
    @State private var notice = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("This phone", store.sources.filter { $0.kind != .wearable })
                let wearables = store.sources.filter { $0.kind == .wearable }
                if !wearables.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Wearables", wearables)
                        Text("A wearable can be chosen once its firmware can hand audio to this "
                           + "app. None does today, so picking one keeps recording on the phone "
                           + "and says so.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(JcTheme.muted)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                    }
                }
                if !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .jcScreen("Microphone")
        .task { store.refreshSources() }
    }

    private func section(_ title: String, _ items: [LiveCaptureSource]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel(title)
            GlassGroup {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, source in
                    GlassRow(symbol: source.symbol,
                             title: source.label,
                             subtitle: subtitle(for: source),
                             subtitleLineLimit: 2,
                             last: index == items.count - 1,
                             action: { choose(source) }) {
                        if store.activeSource.id == source.id {
                            JcIcon("checkmark", size: 14).foregroundStyle(JcTheme.accent)
                        } else if !source.available {
                            JcIcon("slash.circle", size: 13).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for source: LiveCaptureSource) -> String? {
        guard source.canStream else {
            return (source.detail.map { $0 + " — " } ?? "") + "not yet streaming"
        }
        return source.detail
    }

    private func choose(_ source: LiveCaptureSource) {
        notice = store.select(source: source) ?? ""
    }
}
