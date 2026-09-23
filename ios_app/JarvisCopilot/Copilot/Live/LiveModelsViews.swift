import SwiftUI

// MARK: - Settings: what runs on this phone

/// Every model Live uses on the phone, what it does, and whether it is here —
/// with the downloads started, followed and removed from the same rows.
struct LiveOnPhoneSection: View {
    let store: LiveStore
    /// The server's voiceprint model id, from the shared Live config.
    let serverEmbedModel: String

    @State private var models = LiveModels.shared
    @State private var confirming: LiveModelKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("On this phone")
            GlassGroup {
                GlassRow(symbol: "waveform", title: "Live words",
                         subtitle: liveWordsSubtitle, subtitleLineLimit: 3) {
                    badge(store.preparing ? "\(Int(store.prepareProgress * 100))%"
                          : store.sttNotice.isEmpty ? "On" : "Server",
                          tint: store.sttNotice.isEmpty ? JcTheme.success : JcTheme.amber)
                }
                ForEach(LiveModelKind.allCases) { kind in
                    GlassRow(symbol: kind == .parakeet ? "translate" : "character.bubble",
                             title: kind.title, subtitle: subtitle(kind), subtitleLineLimit: 4) {
                        control(kind)
                    }
                }
                GlassRow(symbol: "person.wave.2", title: "Voiceprints",
                         subtitle: "WeSpeaker ResNet34, built into the app (25 MB). The phone "
                                 + "makes each speaker's voiceprint; the server matches it "
                                 + "against the voices it knows.",
                         subtitleLineLimit: 4) {
                    voiceprintBadge
                }
                GlassRow(symbol: "globe", title: "Translation",
                         subtitle: "Apple, on this phone. A language's pack downloads the first "
                                 + "time it is heard; the server translates what the phone can't.",
                         subtitleLineLimit: 4, last: true) {
                    badge("On", tint: JcTheme.success)
                }
            }
            Text(footer)
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        .onAppear { models.refresh() }
        .confirmationDialog(confirming.map { "Download \($0.title)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let kind = confirming {
                Button("Download \(Self.size(kind.approxBytes))") { models.download(kind) }
                Button("Not now", role: .cancel) {}
            }
        } message: {
            Text("It runs entirely on this iPhone. Best on Wi-Fi — the download continues "
               + "if you close this screen.")
        }
    }

    private var liveWordsSubtitle: String {
        if store.preparing { return "Downloading Apple's speech model for your language." }
        if !store.sttNotice.isEmpty { return store.sttNotice }
        let primary = store.config.primaryLanguage.isEmpty ? "your language"
            : (LiveLanguageName.name(store.config.primaryLanguage) ?? store.config.primaryLanguage)
        return "Apple's recogniser, listening in \(primary). Words appear as they are said."
    }

    private func subtitle(_ kind: LiveModelKind) -> String {
        switch models.state(kind) {
        case .failed(let why): return kind.detail + "\nLast try failed: \(why)"
        default: return kind.detail
        }
    }

    @ViewBuilder
    private func control(_ kind: LiveModelKind) -> some View {
        switch models.state(kind) {
        case .absent:
            Button { confirming = kind } label: {
                Text("Get · \(Self.size(kind.approxBytes))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .jcLiquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)
        case .downloading(let fraction, _):
            HStack(spacing: 8) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
                Button { models.cancel(kind) } label: { JcIcon("xmark", size: 12) }
                    .buttonStyle(.plain)
                    .foregroundStyle(JcTheme.muted)
                    .accessibilityLabel("Cancel download")
            }
        case .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            Menu {
                Button("Remove from this iPhone", role: .destructive) { models.remove(kind) }
            } label: {
                badge("On phone", tint: JcTheme.success)
            }
        case .failed:
            Button { models.download(kind) } label: {
                badge("Retry", tint: JcTheme.amber)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var voiceprintBadge: some View {
        if serverEmbedModel == LiveVoiceprint.modelID {
            badge("Matches server", tint: JcTheme.success)
        } else if serverEmbedModel.isEmpty {
            badge("Server not reported", tint: JcTheme.muted)
        } else {
            // The interlock: vectors from two checkpoints are not comparable, so
            // the server identifies from the audio instead. Read-only here on
            // purpose — an edited id would corrupt identity on every device.
            badge("Server uses another model", tint: JcTheme.amber)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var footer: String {
        let here = LiveModelKind.allCases.filter { models.state($0) == .ready }
        guard !here.isEmpty else {
            return "Without the downloads, lines are corrected on the server, a few seconds later."
        }
        let bytes = here.reduce(Int64(0)) { $0 + $1.approxBytes }
        return "\(Self.size(bytes)) of models on this iPhone. Each line is re-heard here the "
             + "moment it ends; nothing waits on the server."
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                            detail: "\(phase) · \(LiveOnPhoneSection.size(got)) of "
                                  + "\(LiveOnPhoneSection.size(kind.approxBytes))",
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
                        detail: "It will be used from the next recording.", done: true)
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
