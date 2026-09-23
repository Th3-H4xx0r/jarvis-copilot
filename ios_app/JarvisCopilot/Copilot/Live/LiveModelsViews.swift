import SwiftUI

// MARK: - A radio choice

/// One option of a choice where exactly one holds: a ring on the leading
/// edge, filled when it is the one. The settings used to put "On" beside rows
/// that were not switches, which read as a control that could not be moved.
struct LiveRadioRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var last: Bool
    let action: () -> Void
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, selected: Bool, last: Bool = false,
         action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.last = last
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? JcTheme.accent : JcTheme.muted.opacity(0.55),
                                          lineWidth: 2)
                        if selected { Circle().fill(JcTheme.accent).padding(5) }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                            .multilineTextAlignment(.leading)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(JcText.small)
                                .foregroundStyle(JcTheme.muted)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !last {
                Rectangle().fill(JcTheme.glassBorder)
                    .frame(height: 1)
                    .padding(.leading, 50)
            }
        }
    }
}

extension LiveRadioRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, selected: Bool, last: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, selected: selected, last: last,
                  action: action) { EmptyView() }
    }
}

/// A small muted note under a settings group.
struct LiveSettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }
}

enum LiveBytes {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Settings: who hears other languages

/// Server, or a model on this phone — one radio choice, with the download it
/// needs started by picking it and followed on the row that asked for it.
struct LiveHearingSection: View {
    @State private var models = LiveModels.shared
    @State private var confirming: LiveHearing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Other languages, heard by")
            GlassGroup {
                ForEach(Array(LiveHearing.allCases.enumerated()), id: \.element) { index, choice in
                    LiveRadioRow(title: choice.title,
                                 subtitle: subtitle(choice),
                                 selected: models.hearing == choice,
                                 last: index == LiveHearing.allCases.count - 1,
                                 action: { pick(choice) }) {
                        status(choice)
                    }
                }
            }
            LiveSettingsNote(models.hearing == .server
                ? "Apple writes down every line in your language as it is said. A line in "
                  + "another language is re-heard on the server and corrected a few seconds later."
                : "Apple writes down every line as it is said; the moment it ends, this iPhone "
                  + "re-hears it and corrects one spoken in another language. The server still "
                  + "checks the lines the phone can't place.")
        }
        .onAppear { models.refresh() }
        .confirmationDialog(confirming.map { "Download \(LiveBytes.text($0.bytesToGet))?" } ?? "",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let choice = confirming {
                Button("Download") { models.choose(choice) }
                Button("Not now", role: .cancel) {}
            }
        } message: {
            Text("It runs entirely on this iPhone. Best on Wi-Fi; the download carries on "
               + "if you close this screen.")
        }
    }

    /// Picking a choice that needs a download asks first: half a gigabyte is
    /// not something a stray tap should start on a cellular plan.
    private func pick(_ choice: LiveHearing) {
        guard choice != models.hearing else { return }
        if choice.bytesToGet > 0 { confirming = choice } else { models.choose(choice) }
    }

    private func subtitle(_ choice: LiveHearing) -> String {
        for kind in choice.kinds {
            if case .failed(let why) = models.state(kind) {
                return choice.detail + "\nThe download failed: \(why)"
            }
        }
        return choice.detail
    }

    /// The chosen row says how its download is going; the others say what
    /// picking them would cost.
    @ViewBuilder
    private func status(_ choice: LiveHearing) -> some View {
        let chosen = models.hearing == choice
        if chosen, let (kind, fraction) = downloading(choice) {
            HStack(spacing: 8) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
                Button { models.cancel(kind) } label: { JcIcon("xmark", size: 12) }
                    .buttonStyle(.plain)
                    .foregroundStyle(JcTheme.muted)
                    .accessibilityLabel("Cancel download")
            }
        } else if chosen, choice.kinds.contains(where: { models.state($0) == .preparing }) {
            ProgressView().controlSize(.small)
        } else if chosen, let failed = choice.kinds.first(where: { models.state($0).isFailed }) {
            Button { models.download(failed) } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.amber)
            }
            .buttonStyle(.plain)
        } else if choice.bytesToGet > 0 {
            Text(LiveBytes.text(choice.bytesToGet))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(JcTheme.muted)
        }
    }

    private func downloading(_ choice: LiveHearing) -> (LiveModelKind, Double)? {
        for kind in choice.kinds {
            if case .downloading(let fraction, _) = models.state(kind) { return (kind, fraction) }
        }
        return nil
    }
}

// MARK: - Settings: what this phone is running

/// Read-only, and it looks it: a tick or a warning, never a word like "On"
/// beside a row that cannot be switched.
struct LivePhoneInfoSection: View {
    let store: LiveStore
    /// The server's voiceprint model id, from the shared Live config.
    let serverEmbedModel: String

    @State private var models = LiveModels.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("On this phone")
            GlassGroup {
                GlassRow(symbol: "waveform", title: "Apple speech",
                         subtitle: speechSubtitle, subtitleLineLimit: 3) {
                    if store.preparing {
                        Text("\(Int(store.prepareProgress * 100))%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(JcTheme.text)
                    } else {
                        mark(ok: store.sttNotice.isEmpty)
                    }
                }
                GlassRow(symbol: "person.wave.2", title: "Voiceprints",
                         subtitle: voiceprintSubtitle, subtitleLineLimit: 3) {
                    mark(ok: serverEmbedModel == LiveVoiceprint.modelID)
                }
                NavigationLink {
                    LiveDownloadsScreen()
                } label: {
                    GlassRow(symbol: "arrow.down.circle", title: "Downloads",
                             subtitle: downloadsSubtitle, last: true)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { models.refresh() }
    }

    private var speechSubtitle: String {
        if store.preparing { return "Downloading Apple's speech model for your language." }
        if !store.sttNotice.isEmpty { return store.sttNotice }
        let primary = store.config.primaryLanguage.isEmpty ? "your language"
            : (LiveLanguageName.name(store.config.primaryLanguage) ?? store.config.primaryLanguage)
        return "Writes down \(primary) as it is said."
    }

    private var voiceprintSubtitle: String {
        if serverEmbedModel == LiveVoiceprint.modelID {
            return "Made on this iPhone (built in, 25 MB) and matched on the server."
        }
        if serverEmbedModel.isEmpty {
            return "Made on this iPhone. The server hasn't said which model it uses."
        }
        // The interlock: vectors from two checkpoints are not comparable.
        return "The server uses another model, so it works voices out from the audio instead."
    }

    private var downloadsSubtitle: String {
        let here = LiveModelKind.allCases.filter { models.state($0) == .ready }
        guard !here.isEmpty else { return "Nothing downloaded." }
        return "\(LiveBytes.text(models.bytesOnDisk)) · "
             + here.map(\.shortName).joined(separator: ", ")
    }

    private func mark(ok: Bool) -> some View {
        JcIcon(ok ? "checkmark.circle.fill" : "exclamationmark.circle", size: 17)
            .foregroundStyle(ok ? JcTheme.success : JcTheme.amber)
            .accessibilityLabel(ok ? "Working" : "Needs attention")
    }
}

/// The downloaded models, and the only place one is deleted.
struct LiveDownloadsScreen: View {
    @State private var models = LiveModels.shared
    @State private var removing: LiveModelKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Models")
                GlassGroup {
                    ForEach(Array(LiveModelKind.allCases.enumerated()), id: \.element) { index, kind in
                        GlassRow(symbol: kind == .parakeet ? "translate" : "character.bubble",
                                 title: kind.title,
                                 subtitle: "\(kind.detail) \(LiveBytes.text(kind.approxBytes)).",
                                 subtitleLineLimit: 3,
                                 last: index == LiveModelKind.allCases.count - 1) {
                            trailing(kind)
                        }
                    }
                }
                LiveSettingsNote("Pick a model under \"Other languages, heard by\" to download it. "
                               + "Removing one the phone is using moves that choice back to "
                               + "what is left.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .jcScreen("Downloads")
        .onAppear { models.refresh() }
        .confirmationDialog(removing.map { "Remove \($0.shortName)?" } ?? "",
                            isPresented: Binding(get: { removing != nil },
                                                 set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            if let kind = removing {
                Button("Remove \(LiveBytes.text(kind.approxBytes))", role: .destructive) {
                    models.remove(kind)
                }
                Button("Keep it", role: .cancel) {}
            }
        } message: {
            Text("Getting it back means downloading it again.")
        }
    }

    @ViewBuilder
    private func trailing(_ kind: LiveModelKind) -> some View {
        switch models.state(kind) {
        case .ready:
            Button { removing = kind } label: {
                Text("Remove")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.danger)
            }
            .buttonStyle(.plain)
        case .downloading(let fraction, _):
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(JcTheme.text)
        case .preparing:
            ProgressView().controlSize(.small)
        case .absent, .failed:
            Text("Not downloaded")
                .font(.system(size: 12.5))
                .foregroundStyle(JcTheme.muted)
        }
    }
}

// MARK: - The popup

/// Shown over Live whenever a model is downloading or being prepared, so a
/// half-gigabyte download is never happening where nobody can see it.
struct LiveModelPopup: ViewModifier {
    let store: LiveStore
    @State private var models = LiveModels.shared
    /// The card the user tucked away. Keyed, so the next download shows again.
    @State private var hidden: String?

    struct Card: Equatable {
        var key: String
        var symbol: String
        var title: String
        var detail: String
        var fraction: Double?
        var cancel: LiveModelKind?
        var done = false
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let card, card.key != hidden {
                    LiveModelPopupCard(card: card,
                                       hide: { hidden = card.key },
                                       cancel: card.cancel.map { kind in { models.cancel(kind) } })
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: card?.key)
            .task(id: models.justFinished) {
                guard models.justFinished != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                models.dismissFinished()
            }
    }

    private var card: Card? {
        if let busy = models.busy {
            let kind = busy.kind
            switch busy.state {
            case .downloading(let fraction, let phase):
                let got = Int64(Double(kind.approxBytes) * fraction)
                return Card(key: "download-\(kind.rawValue)", symbol: "arrow.down.circle",
                            title: "Downloading \(kind.title)",
                            detail: "\(phase) · \(LiveBytes.text(got)) of "
                                  + "\(LiveBytes.text(kind.approxBytes))",
                            fraction: fraction, cancel: kind)
            default:
                return Card(key: "prepare-\(kind.rawValue)", symbol: "cpu",
                            title: "Getting \(kind.title) ready",
                            detail: "Loading it onto this iPhone's Neural Engine. The first "
                                  + "time takes a few seconds; after that it is instant.",
                            fraction: nil)
            }
        }
        if store.preparing {
            return Card(key: "apple-speech", symbol: "arrow.down.circle",
                        title: "Downloading Apple's speech model",
                        detail: "Needed once, so this phone can write down what it hears.",
                        fraction: store.prepareProgress)
        }
        if let done = models.justFinished {
            return Card(key: "done-\(done.rawValue)", symbol: "checkmark.circle",
                        title: "\(done.title) is on this iPhone",
                        detail: "Lines are re-heard with it from now on.", done: true)
        }
        return nil
    }
}

struct LiveModelPopupCard: View {
    let card: LiveModelPopup.Card
    let hide: () -> Void
    let cancel: (() -> Void)?

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    JcIcon(card.symbol, size: 20)
                        .foregroundStyle(card.done ? JcTheme.success : JcTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                        Text(card.detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !card.done {
                    if let fraction = card.fraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(JcTheme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(JcTheme.accent)
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        if let cancel {
                            Button("Cancel", action: cancel)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(JcTheme.muted)
                        }
                        Button("Hide", action: hide)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(JcTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// The model-download popup, for any screen Live can be on.
    func liveModelPopup(_ store: LiveStore) -> some View {
        modifier(LiveModelPopup(store: store))
    }
}
