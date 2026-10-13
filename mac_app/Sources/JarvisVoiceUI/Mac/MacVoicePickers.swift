import SwiftUI

/// The session and model pickers.
///
/// Same choices as the phone's, driven by the same two stores —
/// `VoiceSessionSelection` and `VoiceModelStore` — so a model picked here is the
/// model the next turn carries, and a chat picked here is the one voice writes
/// into, exactly as on the phone.
///
/// Drawn INSIDE the panel, not as a menu. This panel's usual home is a transient
/// `NSPopover`, and a menu is its own window: opening one is a click outside the
/// popover, so the popover closes and takes the menu with it. Nothing appears,
/// and the chip reads as dead. Three menu constructions were tried against that
/// — SwiftUI's `Menu`, an `NSButton` popping one from its action, and an
/// `NSPopUpButton` — and the popover defeats all three, because the problem was
/// never the control.
///
/// A list drawn in the panel's own hierarchy has no window to lose. It also
/// behaves the same in the pop-out window, where a menu would have worked.

/// One row of a picker.
struct PickerRow: Identifiable {
    enum Kind { case item, header, choice }

    let id = UUID()
    var kind: Kind = .item
    var title: String = ""
    var checked: Bool = false
    var action: () -> Void = {}
    /// For `.choice`: the options, side by side.
    var choices: [PickerChoice] = []

    static func header(_ title: String) -> PickerRow {
        PickerRow(kind: .header, title: title)
    }

    static func choice(_ title: String, _ choices: [PickerChoice]) -> PickerRow {
        PickerRow(kind: .choice, title: title, choices: choices)
    }
}

/// One option of a `.choice` row. Choosing it does NOT close the card: the two
/// conversation settings sit together, and setting one then the other should
/// not take two trips.
struct PickerChoice: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void
}

/// Which picker is open, if any.
enum MacPickerKind: Identifiable {
    case session, model
    var id: Self { self }

    var title: String {
        switch self {
        case .session: return "Voice session"
        case .model: return "Voice settings"
        }
    }
}

// MARK: - Session

@MainActor
@Observable
final class MacSessionPicker {
    private let selection = VoiceSessionSelection.shared
    /// How many chats the picker offers. The server returns every session
    /// there has ever been — the first version of this listed all of them and
    /// drew a menu taller than the screen. "Recent chats" is what the phone's
    /// picker calls this list, and recent is what it should mean.
    static let recentLimit = 10

    private(set) var sessions: [ChatSessionSummary] = []
    private var loading = false

    var chipLabel: String { selection.chipLabel }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // A listing failure is not worth a banner — the default session always
        // works, and the chip still says which one is current.
        if let list = try? await SessionsAPI().list() {
            sessions = Array(list.prefix(Self.recentLimit))
            // Drops a target whose chat was deleted elsewhere, and keeps the
            // chip's title current once a new chat gets its name.
            // Reconciled against the FULL list: a chat further down it is still
            // a live target, and pruning the selection to the visible ten would
            // throw away a perfectly good one.
            selection.reconcile(with: list)
        }
    }

    func rows(onChange: @escaping () -> Void) -> [PickerRow] {
        var out = [PickerRow(title: "Voice",
                             checked: selection.target.sessionID == nil,
                             action: { self.choose(.defaultVoice, onChange) })]
        if !sessions.isEmpty {
            out.append(.header("Recent chats"))
            for session in sessions {
                out.append(PickerRow(
                    title: session.displayTitle,
                    checked: selection.target.sessionID == session.id,
                    action: {
                        self.choose(.session(id: session.id, title: session.displayTitle),
                                    onChange)
                    }))
            }
        }
        out.append(.header(""))
        out.append(PickerRow(title: "New session…", action: {
            Task {
                guard (try? await self.selection.startNewSession()) != nil else { return }
                onChange()
                await self.load()
            }
        }))
        return out
    }

    private func choose(_ target: VoiceSessionSelection.Target, _ onChange: () -> Void) {
        selection.select(target)
        onChange()
    }
}

// MARK: - Model

/// The harnesses this Mac can pick, from `GET /api/harnesses`.
///
/// Read here rather than through the phone's `HarnessStore`, which is not in
/// this build and would not do anyway: it mirrors the SERVER's Voice pick into
/// `sel_voice_harness`, the key that holds this Mac's own.
struct MacHarnessList: Equatable {
    struct Harness: Equatable {
        let id: String
        let title: String
        /// No validation problems — one with problems would run as Single.
        let ok: Bool
    }

    var harnesses: [Harness] = []
    /// What Voice runs on the server (its own pick, else the one default): what
    /// "Voice default" follows.
    var voiceDefaultID = ""

    init() {}

    init(json: [String: Any]) {
        for h in (json["harnesses"] as? [[String: Any]]) ?? [] {
            guard let id = h["id"] as? String, !id.isEmpty else { continue }
            let name = (h["name"] as? String) ?? id
            let title = [h["icon"] as? String, name].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
            harnesses.append(Harness(id: id, title: title, ok: ((h["problems"] as? [Any]) ?? []).isEmpty))
        }
        voiceDefaultID = ((json["assignments"] as? [String: Any])?["voice"] as? String) ?? ""
    }

    func title(for id: String) -> String { harnesses.first { $0.id == id }?.title ?? id }
}

/// What a row of the voice picker sets on this Mac.
enum MacVoicePick: Equatable {
    /// No pick of its own: the server's Voice harness answers.
    case voiceDefault
    case harness(String)
    /// The Single harness, answering with this model.
    case model(ChatModel)
}

@MainActor
@Observable
final class MacModelPicker {
    private let models: VoiceModelStore
    @ObservationIgnored private let api: JarvisAPI
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var harnessList = MacHarnessList()
    /// This Mac's harness (`sel_voice_harness`, which the shared voice
    /// transport sends as the turn's `harness_id`); nil = Voice default.
    private(set) var harnessID: String?

    /// Dependencies are `nil`-defaulted and built in the body: a default argument
    /// is evaluated in a nonisolated context, which `@MainActor` values can't be.
    init(api: JarvisAPI = .shared, models: VoiceModelStore? = nil, defaults: UserDefaults = .standard) {
        self.api = api
        self.models = models ?? .shared
        self.defaults = defaults
        let stored = defaults.string(forKey: voiceHarnessDefaultsKey)
        harnessID = stored?.isEmpty == false ? stored : nil
    }

    /// A model with no harness — a pick from before harnesses — is an explicit
    /// pick the server answers as Single, so it reads as Single here too.
    private var runsSingle: Bool {
        harnessID == "single" || (harnessID == nil && models.selectedModelID != nil)
    }

    /// The harness's name, the model for Single, else "Voice default".
    var chipLabel: String {
        if let id = harnessID, id != "single" { return harnessList.title(for: id) }
        if models.selectedModelID != nil { return models.chipLabel }
        return harnessID == "single" ? harnessList.title(for: "single") : "Voice default"
    }

    /// "Voice default (Fast + Claude)", bare until the harnesses load.
    var voiceDefaultTitle: String {
        let id = harnessList.voiceDefaultID
        return id.isEmpty ? "Voice default" : "Voice default (\(harnessList.title(for: id)))"
    }

    func load() async {
        await models.load()
        await SpeechEngineStore.shared.load()
        await loadHarnesses()
    }

    /// A failure keeps the last list: "Voice default" and the models still work.
    func loadHarnesses() async {
        guard let json = try? await api.get("/api/harnesses").object() else { return }
        harnessList = MacHarnessList(json: json)
    }

    /// How the conversation works, then what answers. The conversation settings
    /// come first — they change every turn, and used to sit under the whole
    /// catalogue — and live in this card rather than chips of their own: the
    /// phone keeps them in the same sheet as the model, and the top bar has no
    /// room for more.
    func rows(store: VoiceStore) -> [PickerRow] {
        var out = Self.conversationRows(store: store)
        out.append(.header(""))
        out += harnessRows()
        return out
    }

    /// What answers on this Mac: "Voice default" (the server's Voice harness),
    /// a harness, or a model (Single with that model). A pick for this Mac only —
    /// the default everything else follows is set in Settings on the web or phone.
    func harnessRows() -> [PickerRow] {
        var out: [PickerRow] = [.header("Harness")]
        out.append(PickerRow(title: voiceDefaultTitle,
                             checked: harnessID == nil && models.selectedModelID == nil,
                             action: { self.choose(.voiceDefault) }))
        for harness in harnessList.harnesses where harness.ok && harness.id != "single" {
            out.append(PickerRow(title: harness.title,
                                 checked: harnessID == harness.id,
                                 action: { self.choose(.harness(harness.id)) }))
        }
        if let catalog = models.catalog {
            for provider in catalog.providers {
                // "Model · Anthropic API": in the Settings form a header opens a
                // section, so a bare "Model" header above these would be lost.
                out.append(.header(provider.isEmpty ? "Model" : "Model · \(provider)"))
                for model in catalog.models(for: provider) {
                    out.append(PickerRow(title: model.label,
                                         checked: runsSingle && models.selectedModelID == model.id,
                                         action: { self.choose(.model(model)) }))
                }
            }
        } else {
            out.append(.header(models.loading ? "Loading…" : (models.loadError ?? "No models")))
        }
        return out
    }

    func choose(_ pick: MacVoicePick) {
        switch pick {
        case .voiceDefault:
            setHarness(nil)
            models.select(nil)
        case .harness(let id):
            setHarness(id)
            // A harness picks its own models; a leftover one would ride along unused.
            models.select(nil)
        case .model(let model):
            setHarness("single")
            models.select(model)
        }
    }

    private func setHarness(_ id: String?) {
        harnessID = id
        if let id { defaults.set(id, forKey: voiceHarnessDefaultsKey) }
        else { defaults.removeObject(forKey: voiceHarnessDefaultsKey) }
    }

    static func conversationRows(store: VoiceStore) -> [PickerRow] {
        let enabled = !store.isActive
        var out: [PickerRow] = [
            .choice("Turn mode", [
                PickerChoice(symbol: "waveform", title: VoiceMode.realtime.label,
                             selected: store.mode == .realtime, enabled: enabled,
                             action: { Task { await store.setMode(.realtime) } }),
                PickerChoice(symbol: "hand.tap", title: VoiceMode.quality.label,
                             selected: store.mode == .quality, enabled: enabled,
                             action: { Task { await store.setMode(.quality) } }),
            ]),
            .choice("Transcription", [
                PickerChoice(symbol: "laptopcomputer", title: VoiceTranscription.onDevice.label,
                             selected: store.transcription == .onDevice, enabled: enabled,
                             action: { Task { await store.setTranscription(.onDevice) } }),
                PickerChoice(symbol: "waveform", title: VoiceTranscription.server.label,
                             selected: store.transcription == .server, enabled: enabled,
                             action: {
                                 Task {
                                     await store.setTranscription(.server)
                                     await SpeechEngineStore.shared.useSonioxForVoice()
                                 }
                             }),
            ]),
        ]
        // Only when Soniox is not what will actually hear the turn.
        let speech = SpeechEngineStore.shared
        if let fallback = store.onDeviceFallback {
            out.append(.header("On-device is not available here (\(fallback)), so Soniox is used."))
        } else if store.transcription == .server, speech.loaded, !speech.sonioxReady {
            out.append(.header("Soniox has no key on the server yet, so the server's own model transcribes."))
        }
        switch store.transcriptionStatus {
        case .preparing(let fraction):
            out.append(.header(fraction.map { "Downloading speech model… \(Int($0 * 100))%" }
                               ?? "Preparing…"))
        case .failed(let message):
            out.append(.header(message))
        case .ready, .idle:
            break
        }
        return out
    }
}

// MARK: - Views

/// The chip: a symbol, the current choice, a chevron. An ordinary SwiftUI
/// `Button`, which — unlike `Menu` — hit-tests the whole shape it is given.
struct MacPickerChip: View {
    /// Longest chat title or model name the chip shows.
    ///
    /// Clipped as a STRING, not with `frame(maxWidth:)`. A capped frame makes
    /// the chip claim that width whether its text needs it or not, so two chips
    /// push each other across the row and the chevron ends up an inch from the
    /// word it belongs to. Cutting the string keeps the chip exactly as wide as
    /// what it says.
    static let titleLimit = 16

    static func clipped(_ text: String) -> String {
        text.count <= titleLimit ? text
            : String(text.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    let symbol: String
    let text: String
    var enabled: Bool = true
    var accessibilityLabel: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(JcTheme.accent.opacity(enabled ? 1 : 0.45))
                Text(Self.clipped(text))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(JcTheme.text.opacity(enabled ? 0.75 : 0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // `frame(maxWidth:)` would make the chip CLAIM that width whether it
            // needs it or not, and two of them then push each other across the
            // row. The text is what is capped.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel.isEmpty ? text : accessibilityLabel)
    }
}

/// The open picker: a scrim over the panel and a card of rows.
struct MacPickerSheet: View {
    let title: String
    let rows: [PickerRow]
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Tapping anywhere outside the card closes it, the way dismissing a
            // menu does — and it must swallow the tap, or the control underneath
            // takes it too.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(JcTheme.muted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .header:
                                if !row.title.isEmpty {
                                    Text(row.title.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .tracking(0.8)
                                        .foregroundStyle(JcTheme.muted.opacity(0.8))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 3)
                                } else {
                                    Divider().opacity(0.25).padding(.vertical, 5)
                                }
                            case .choice:
                                MacChoiceRow(title: row.title, choices: row.choices)
                            case .item:
                                Button {
                                    row.action()
                                    onDismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(JcTheme.accent)
                                            .opacity(row.checked ? 1 : 0)
                                            .frame(width: 11)
                                        Text(row.title)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(JcTheme.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(MacPickerRowStyle())
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .frame(maxHeight: 280)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(Color(jcHex: 0x15151C))
                shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .padding(.horizontal, 10)
            .padding(.top, 32)
        }
    }
}

/// A labelled pair of options as one segmented control: icon and name in each
/// half, the chosen half filled with the accent.
private struct MacChoiceRow: View {
    let title: String
    let choices: [PickerChoice]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(JcTheme.muted.opacity(0.8))
            HStack(spacing: 2) {
                ForEach(choices) { choice in
                    Button(action: choice.action) {
                        HStack(spacing: 5) {
                            Image(systemName: choice.symbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(choice.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(choice.selected ? JcTheme.cyan : JcTheme.text.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if choice.selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(JcTheme.cyan.opacity(0.5), lineWidth: 1))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!choice.enabled || choice.selected)
                    .accessibilityAddTraits(choice.selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
            .opacity(choices.allSatisfy(\.enabled) ? 1 : 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// Rows highlight under the pointer, as menu rows do.
private struct MacPickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed
                        ? Color.white.opacity(0.10) : Color.clear)
            .onHover { hovering = $0 }
    }
}
