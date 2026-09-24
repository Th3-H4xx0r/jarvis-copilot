import SwiftUI
#if canImport(Speech)
import Speech
#endif

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
    /// The model catalogue, shared with the Voice picker, purely to turn the
    /// server's effective model id into a name a person recognises.
    @State private var models = VoiceModelStore.shared
    @State private var pickingModel = false
    /// Who hears Live recordings lives with the other speech settings on the server.
    @State private var speech = SpeechEngineStore.shared

    private static let windowChoices = [30, 60, 120, 300, 600]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    device
                    transcription
                    language
                    LiveHearingSection()
                    LiveSpeakersSection()
                    translation
                    watchers
                    window
                    factCheckWindow
                    rollover
                    replies
                    LivePhoneInfoSection(store: store, serverEmbedModel: draft.embedModel)
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
            .jcScreen("Live settings")
            .liveModelPopup(store)
            .sheet(isPresented: $pickingModel) {
                CatalogModelPickerSheet(
                    title: "Watchers model",
                    catalog: models.catalog,
                    selectedID: draft.model.isEmpty ? nil : draft.model,
                    autoSubtitle: models.catalog.flatMap(appModel).map {
                        "Follow the app — \(label($0, in: models.catalog!))."
                    } ?? "Follow the app's own model.",
                    load: { await models.load() },
                    select: { picked in
                        draft.model = picked?.id ?? ""
                        push()
                    })
            }
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
            await models.load()
        }
    }

    // MARK: - This device

    private var device: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Recording")
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
                          "On demand, from the Fact-check button beside Record.",
                          get: { draft.factCheck }, set: { draft.factCheck = $0 })
                toggleRow("brain", "Remember facts",
                          "Writes durable facts to your memory provider.",
                          get: { draft.memoryExtraction }, set: { draft.memoryExtraction = $0 })
                toggleRow("doc.text", "End-of-session summary",
                          "Summary, decisions and action items when a session ends.",
                          get: { draft.artifacts }, set: { draft.artifacts = $0 })
                GlassRow(symbol: "sparkles",
                         title: "Model",
                         subtitle: modelSubtitle,
                         subtitleLineLimit: 2,
                         last: true,
                         action: { pickingModel = true }) {
                    if modelName == nil {
                        ProgressView().controlSize(.small).tint(JcTheme.accent)
                    } else {
                        JcIcon("chevron.right", size: 13).foregroundStyle(JcTheme.muted)
                    }
                }
            }
            LiveSettingsNote("Shared with the web. The watchers, and translation on the "
                           + "server, run on this model; Auto follows the app's own.")
        }
    }

    // MARK: - Translation

    /// Where a line in another language is translated — or whether at all.
    ///
    /// Off is the server's `live.translate`, shared with the web. Phone or
    /// Server is this phone's own choice: its language packs are here.
    private enum TranslateChoice: CaseIterable {
        case off, phone, server
    }

    private var translateChoice: TranslateChoice {
        guard draft.translate else { return .off }
        return store.settings.translateOnPhone ? .phone : .server
    }

    private func chooseTranslate(_ choice: TranslateChoice) {
        switch choice {
        case .off:
            draft.translate = false
        case .phone:
            draft.translate = true
            store.settings.translateOnPhone = true
        case .server:
            draft.translate = true
            store.settings.translateOnPhone = false
        }
        push()
    }

    // MARK: - Who transcribes

    /// This phone (Apple) or a server engine such as Soniox — `speech.surfaces.live`.
    private var transcription: some View {
        let s = speech.settings
        let options = [SpeechSettings.edge] + s.streamingEngines.map(\.name)
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Transcription")
            GlassGroup {
                ForEach(Array(options.enumerated()), id: \.element) { index, name in
                    let info = s.engine(name)
                    let usable = name == SpeechSettings.edge || (info?.available ?? false)
                    LiveRadioRow(title: s.label(for: name),
                                 subtitle: name == SpeechSettings.edge
                                    ? "Apple, on this iPhone: private, one language at a time."
                                    : (usable ? "On the server: every language in one stream, with "
                                              + "translation and who said what."
                                              : info?.reason),
                                 selected: s.live == name,
                                 last: index == options.count - 1,
                                 action: { Task { await speech.setSurface("live", to: name) } })
                        .disabled(!usable && s.live != name)
                        .opacity(usable || s.live == name ? 1 : 0.5)
                }
            }
            NavigationLink {
                SpeechEngineScreen()
            } label: {
                Text("Speech engine settings")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            .buttonStyle(.plain)
            LiveSettingsNote("A recording already running switches when its connection next renews.")
        }
        .task { await speech.load() }
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Translate into \(primaryName)")
            GlassGroup {
                LiveRadioRow(title: "Off",
                             subtitle: "Lines stay in the language they were spoken in.",
                             selected: translateChoice == .off,
                             action: { chooseTranslate(.off) })
                LiveRadioRow(title: "This phone",
                             subtitle: "Apple, on this iPhone: instant and private. A language "
                                     + "this phone has no pack for goes to the server.",
                             selected: translateChoice == .phone,
                             action: { chooseTranslate(.phone) })
                LiveRadioRow(title: "Server",
                             subtitle: "The watchers' model translates each line, a few "
                                     + "seconds later.",
                             selected: translateChoice == .server,
                             last: true,
                             action: { chooseTranslate(.server) })
            }
            LiveSettingsNote("Only lines in another language are translated. Off applies "
                           + "on the web too.")
        }
    }

    // MARK: - How much a fact-check reads

    /// Token ceilings offered for the fact-check window. `live.fact_check_tokens`
    /// on the server; the default of 1000 is the server's, not a second opinion.
    private static let factCheckTokenChoices = [500, 1000, 2000, 4000]

    private var factCheckWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Fact-check")
            GlassGroup {
                GlassRow(symbol: "text.alignleft",
                         title: "How much to check",
                         subtitle: "The last \(draft.factCheckTokens) tokens of the "
                                 + "conversation go to the model.",
                         subtitleLineLimit: 2,
                         last: true) {
                    Picker("", selection: Binding(get: { Self.nearestTokens(draft.factCheckTokens) },
                                                  set: { draft.factCheckTokens = $0; push() })) {
                        ForEach(Self.factCheckTokenChoices, id: \.self) { tokens in
                            Text("\(tokens)").tag(tokens)
                        }
                    }
                    .labelsHidden()
                    .tint(JcTheme.accent)
                }
            }
            Text("Fact-check reads the recent conversation, not one line and not the "
               + "whole recording.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    /// The server may hold a value that is not one of the offered taps (config
    /// edited by hand). Snapped for display rather than shown as a blank picker.
    private static func nearestTokens(_ value: Int) -> Int {
        factCheckTokenChoices.min { abs($0 - value) < abs($1 - value) } ?? 1000
    }

    // MARK: - The model the watchers use

    /// The effective model's human label, or nil while unknown.
    ///
    /// A LABEL, never a bare id fragment: "31b" tells nobody anything. The
    /// catalogue's own name is used when it has one, and the full id otherwise.
    private var modelName: String? {
        guard let catalog = models.catalog else { return nil }
        // The watchers' own pick wins; empty means they follow the app.
        if !draft.model.isEmpty { return label(draft.model, in: catalog) }
        guard let app = appModel(catalog) else { return nil }
        return "\(label(app, in: catalog)) · Auto"
    }

    /// The app's own model, which "Auto" follows.
    private func appModel(_ catalog: ModelCatalog) -> String? {
        let id = (catalog.activeModel?.isEmpty == false ? catalog.activeModel : nil)
            ?? (catalog.defaultModel.isEmpty ? nil : catalog.defaultModel)
        return id?.isEmpty == false ? id : nil
    }

    private func label(_ id: String, in catalog: ModelCatalog) -> String {
        if let match = catalog.models.first(where: { $0.id == id }), !match.label.isEmpty {
            return match.label
        }
        return id
    }

    private var modelSubtitle: String {
        if let modelName { return modelName }
        if models.loadError != nil {
            return "Jarvis couldn't report which model the watchers use."
        }
        return "Asking the server which model the watchers use…"
    }

    // MARK: - Window

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Monitor timing")
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

    // MARK: - New session after
    //
    // Recording is ONE conversation across as many stops and starts as you
    // like: the client always asks to continue the last session, and the server
    // rolls it over once the transcript has grown past the point below. This is
    // where that point is chosen. The server is the only thing that applies it
    // — it knows the model and can answer the same way for every device — so
    // nothing on this screen measures anything.

    /// Shares of the model's context window offered. The server clamps to
    /// 0.05–1.0; these are the ones worth a tap.
    private static let rolloverFractions: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0]

    private var rollover: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("New session after")
            GlassGroup {
                GlassRow(symbol: "square.on.square",
                         title: "Share of model context",
                         subtitle: draft.sessionRolloverTokens > 0
                            ? "Overridden by the token ceiling below."
                            : "A conversation keeps going until its transcript "
                            + "reaches this much of the model's context window.",
                         subtitleLineLimit: 3) {
                    Picker("", selection: Binding(get: { Self.nearestFraction(draft.sessionRolloverFraction) },
                                                  set: { draft.sessionRolloverFraction = $0; push() })) {
                        ForEach(Self.rolloverFractions, id: \.self) { fraction in
                            Text(Self.percentLabel(fraction)).tag(fraction)
                        }
                    }
                    .labelsHidden()
                    .tint(JcTheme.accent)
                    .disabled(draft.sessionRolloverTokens > 0)
                    .opacity(draft.sessionRolloverTokens > 0 ? 0.5 : 1)
                }
                GlassRow(symbol: "number",
                         title: "Or a token ceiling",
                         subtitle: draft.sessionRolloverTokens > 0
                            ? "Rolls over at \(draft.sessionRolloverTokens) tokens."
                            : "Leave at 0 to use the share above.",
                         subtitleLineLimit: 2,
                         last: true) {
                    TextField("0", value: Binding(get: { draft.sessionRolloverTokens },
                                                  set: { draft.sessionRolloverTokens = max(0, $0) }),
                              format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.text)
                        .frame(maxWidth: 90)
                        .onSubmit { push() }
                }
            }
            Text("Stopping and starting continues the same conversation, so short "
               + "bursts add up into one session Jarvis can summarise. Rolling over "
               + "is the server's decision — shared with every device.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    private static func percentLabel(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// The server may hold a fraction that is not one of the offered taps (the
    /// web client, or config.yaml edited by hand). Snapped to the nearest
    /// choice for display rather than shown as a blank picker — and only when
    /// the user actually changes it does that snapped value get written back.
    private static func nearestFraction(_ value: Double) -> Double {
        rolloverFractions.min { abs($0 - value) < abs($1 - value) } ?? 0.5
    }

    // MARK: - Replies

    private var replies: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Replies")
            GlassGroup {
                GlassRow(symbol: "bubble.left",
                         title: "Read insights aloud",
                         subtitle: "In the phone's own voice.",
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

    private var primaryName: String {
        let code = draft.primaryLanguage.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return "your language" }
        return LiveLanguageName.name(code) ?? code
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Your language")
            GlassGroup {
                NavigationLink {
                    LiveLanguageScreen(selected: draft.primaryLanguage) { code in
                        draft.primaryLanguage = code
                        push()
                    }
                } label: {
                    GlassRow(symbol: "character.bubble", title: primaryName,
                             subtitle: "Apple writes it down as it is said, and lines in "
                                     + "other languages are translated into it.",
                             subtitleLineLimit: 3, last: true)
                }
                .buttonStyle(.plain)
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

/// Your language, picked from a list rather than typed as a code: "en" in a
/// text box was the only way to set it, and it said nothing about which
/// languages the phone can actually write down.
struct LiveLanguageScreen: View {
    let selected: String
    let pick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var codes = LiveLanguageScreen.common

    /// Shown until Apple says which languages it transcribes, and on an iOS
    /// too old to ask.
    static let common = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "nb", "fi",
                         "pl", "ru", "uk", "tr", "ar", "he", "hi", "zh", "yue", "ja", "ko",
                         "vi", "th", "id", "ms"]

    private var shown: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let named = codes.map { ($0, LiveLanguageName.name($0) ?? $0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return named.filter { needle.isEmpty || $0.1.lowercased().contains(needle)
                              || $0.0.lowercased().hasPrefix(needle) }
            .map(\.0)
    }

    var body: some View {
        let list = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassGroup {
                    ForEach(Array(list.enumerated()), id: \.element) { index, code in
                        LiveRadioRow(title: LiveLanguageName.name(code) ?? code,
                                     selected: LiveTranslator.primarySubtag(code)
                                        == LiveTranslator.primarySubtag(selected),
                                     last: index == list.count - 1,
                                     action: {
                                         pick(code)
                                         dismiss()
                                     })
                    }
                }
                if list.isEmpty {
                    LiveSettingsNote("No language matches.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .jcScreen("Your language")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search languages")
        .task { codes = await Self.transcribable() }
    }

    /// The languages Apple's recogniser can write down, one entry per
    /// language: its locale is matched to the nearest region when recording
    /// starts, so "English" rather than eleven Englishes.
    static func transcribable() async -> [String] {
        #if canImport(Speech)
        if #available(iOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            var seen = Set<String>()
            let codes = locales.compactMap { $0.language.languageCode?.identifier }
                .filter { seen.insert($0).inserted }
            if !codes.isEmpty { return codes }
        }
        #endif
        return common
    }
}
