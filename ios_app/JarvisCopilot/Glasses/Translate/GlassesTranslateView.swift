import SwiftUI
import Translation

/// Live translation on the glasses: pick the languages and who translates, start,
/// and watch the lines (the lens shows the same).
struct GlassesTranslateView: View {
    private let translator = GlassesTranslator.shared
    @AppStorage(GlassesTranslator.sourceKey) private var source = "es"
    @AppStorage(GlassesTranslator.targetKey) private var target = "en"
    @AppStorage(GlassesTranslator.engineKey) private var engine = GlassesTranslateEngine.onDevice.rawValue
    @AppStorage(GlassesTranslator.onlyTranslationKey) private var onlyTranslation = false
    @AppStorage(GlassesTranslator.fromGlassesKey) private var fromGlasses = true
    @State private var downloading = false
    @State private var downloadNote: String?

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("zh-Hans", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("hi", "Hindi"), ("ar", "Arabic"), ("ru", "Russian"), ("nl", "Dutch"), ("tr", "Turkish"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if translator.phase == .idle || translator.phase == .starting { setup } else { live }
            }
            .padding(.vertical, 16)
        }
        .tint(JcTheme.accent)
        .jcPageChrome("Live translation")
        .modifier(LanguageDownload(active: $downloading, source: source, target: target, note: $downloadNote))
    }

    private func languageRow(_ title: String, _ selection: Binding<String>) -> some View {
        Row {
            HStack {
                Text(title).foregroundStyle(JcTheme.text)
                Spacer()
                Picker(title, selection: selection) { ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) } }
                    .labelsHidden()
                    .tint(JcTheme.muted)
            }
        }
    }

    @ViewBuilder private var setup: some View {
        CardGroup("Languages") {
            languageRow("They speak", $source)
            RowDivider()
            languageRow("Show me", $target)
            RowDivider()
            Row {
                Button("Swap languages", jcIcon: "arrow.left.arrow.right") { (source, target) = (target, source) }
                    .buttonStyle(.plain)
                    .foregroundStyle(JcTheme.accent)
            }
        }
        CardGroup("Translator") {
            Row {
                VStack(alignment: .leading, spacing: 8) {
                    JcSegmented(items: GlassesTranslateEngine.allCases,
                                selection: Binding(get: { GlassesTranslateEngine(rawValue: engine) ?? .onDevice },
                                                   set: { engine = $0.rawValue }),
                                label: { $0.label })
                    Text(GlassesTranslateEngine(rawValue: engine)?.detail ?? "").font(JcText.small).foregroundStyle(JcTheme.muted)
                }
            }
            if engine == GlassesTranslateEngine.onDevice.rawValue {
                RowDivider()
                Row {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(downloading ? "Downloading…" : "Download languages for on-device", jcIcon: "arrow.down.circle") {
                            downloadNote = nil; downloading = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(JcTheme.accent)
                        .disabled(downloading)
                        if let downloadNote { Text(downloadNote).font(JcText.small).foregroundStyle(JcTheme.muted) }
                    }
                }
            }
        }
        CardGroup(footer: "The glasses' microphone hears the person in front of you; each line and its translation show on the lens. Sessions are saved with your AI notes.") {
            Row { Toggle("Lens shows only the translation", isOn: $onlyTranslation) }
            RowDivider()
            Row { Toggle("Start from the glasses", isOn: $fromGlasses) }
        }
        VStack(spacing: 10) {
            if let problem = translator.problem {
                Text(problem).font(JcText.small).foregroundStyle(JcTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await translator.start() }
            } label: {
                HStack(spacing: 8) {
                    if translator.phase == .starting { JcLoader(size: 16) }
                    Label(translator.phase == .starting ? "Starting…" : "Start live translation", jcIcon: "globe")
                }
            }
            .buttonStyle(.jcGlass(full: true))
            .disabled(translator.phase != .idle || source == target)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var live: some View {
        CardGroup {
            Row {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(translator.paused ? JcTheme.amber : JcTheme.danger).frame(width: 8, height: 8)
                        Text(translator.paused ? "Paused on the glasses" :
                                "\(GlassesTranslator.name(source)) → \(GlassesTranslator.name(target)) · \(translator.engineInUse.label)")
                            .font(JcText.body.weight(.medium)).foregroundStyle(JcTheme.muted)
                    }
                    if let problem = translator.problem { Text(problem).font(JcText.small).foregroundStyle(JcTheme.danger) }
                }
            }
        }
        CardGroup("Newest first") {
            let lines = Array(translator.lines.reversed())
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { RowDivider() }
                Row {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.translation.isEmpty ? "…" : line.translation)
                            .font(JcText.body.weight(.semibold)).foregroundStyle(JcTheme.text)
                        Text(line.original).font(JcText.body).foregroundStyle(JcTheme.muted)
                    }
                }
            }
            if !translator.hearing.isEmpty {
                if !lines.isEmpty { RowDivider() }
                Row { Text(translator.hearing).italic().foregroundStyle(JcTheme.muted) }
            }
            if translator.lines.isEmpty && translator.hearing.isEmpty {
                CardEmptyBlock("Listening…", symbol: "waveform")
            }
        }
        Button {
            Task { await translator.stop() }
        } label: {
            Text(translator.phase == .stopping ? "Stopping…" : "Stop")
        }
        .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
        .disabled(translator.phase != .running)
        .padding(.horizontal, 20)
    }
}

/// Downloads Apple's on-device translation models for the picked pair (iOS asks first).
private struct LanguageDownload: ViewModifier {
    @Binding var active: Bool
    let source: String
    let target: String
    @Binding var note: String?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(active ? TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                              target: Locale.Language(identifier: target)) : nil) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { note = "Ready for on-device translation."; active = false }
                } catch {
                    await MainActor.run { note = "Couldn't download: \(error.localizedDescription)"; active = false }
                }
            }
        } else {
            content
        }
    }
}
