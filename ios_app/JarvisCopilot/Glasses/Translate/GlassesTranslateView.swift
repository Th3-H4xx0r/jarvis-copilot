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
        List {
            if translator.phase == .idle || translator.phase == .starting { setup } else { live }
        }
        .navigationTitle("Live translation")
        .modifier(LanguageDownload(active: $downloading, source: source, target: target, note: $downloadNote))
    }

    @ViewBuilder private var setup: some View {
        Section {
            Picker("They speak", selection: $source) { ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) } }
            Picker("Show me", selection: $target) { ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) } }
            Button("Swap languages", jcIcon: "arrow.left.arrow.right") { (source, target) = (target, source) }
        } header: { Text("Languages") }
        Section {
            Picker("Translator", selection: $engine) {
                ForEach(GlassesTranslateEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(GlassesTranslateEngine(rawValue: engine)?.detail ?? "").font(.caption).foregroundStyle(JcTheme.muted)
            if engine == GlassesTranslateEngine.onDevice.rawValue {
                Button(downloading ? "Downloading…" : "Download languages for on-device", jcIcon: "arrow.down.circle") {
                    downloadNote = nil; downloading = true
                }
                .disabled(downloading)
                if let downloadNote { Text(downloadNote).font(.caption).foregroundStyle(JcTheme.muted) }
            }
        } header: { Text("Translator") }
        Section {
            Toggle("Lens shows only the translation", isOn: $onlyTranslation)
            Toggle("Start from the glasses", isOn: $fromGlasses)
        }
        Section {
            Button {
                Task { await translator.start() }
            } label: {
                HStack {
                    Spacer()
                    if translator.phase == .starting { ProgressView() }
                    Label(translator.phase == .starting ? "Starting…" : "Start live translation", jcIcon: "globe")
                        .font(.body.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.jcGlass)
            .disabled(translator.phase != .idle || source == target)
            .listRowBackground(Color.clear)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = translator.problem { Text(problem).foregroundStyle(.red) }
                Text("The glasses' microphone hears the person in front of you; each line and its translation show on the lens. Sessions are saved with your AI notes.")
            }
        }
    }

    @ViewBuilder private var live: some View {
        Section {
            HStack {
                Circle().fill(translator.paused ? Color.orange : Color.red).frame(width: 10, height: 10)
                Text(translator.paused ? "Paused on the glasses" :
                        "\(GlassesTranslator.name(source)) → \(GlassesTranslator.name(target)) · \(translator.engineInUse.label)")
                    .font(.subheadline.weight(.medium)).foregroundStyle(JcTheme.muted)
            }
            if let problem = translator.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        Section {
            ForEach(translator.lines.reversed()) { line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.translation.isEmpty ? "…" : line.translation)
                        .font(.body.weight(.semibold)).foregroundStyle(JcTheme.text)
                    Text(line.original).font(.subheadline).foregroundStyle(JcTheme.muted)
                }
                .padding(.vertical, 2)
            }
            if !translator.hearing.isEmpty {
                Text(translator.hearing).italic().foregroundStyle(JcTheme.muted)
            }
            if translator.lines.isEmpty && translator.hearing.isEmpty {
                Text("Listening…").foregroundStyle(JcTheme.muted)
            }
        } header: { Text("Newest first") }
        Section {
            Button {
                Task { await translator.stop() }
            } label: {
                HStack { Spacer(); Text(translator.phase == .stopping ? "Stopping…" : "Stop").font(.headline); Spacer() }
                    .padding(.vertical, 6)
            }
            .buttonStyle(.jcGlass(tint: .red))
            .disabled(translator.phase != .running)
            .listRowBackground(Color.clear)
        }
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
