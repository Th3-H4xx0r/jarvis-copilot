import Speech
import SwiftUI

/// What this phone can transcribe, and what to call it.
@MainActor
enum LiveLanguageCatalog {

    /// The languages `SpeechTranscriber` supports on THIS device, as BCP-47.
    ///
    /// Empty on systems older than the analyzer engine: there the recogniser is
    /// fixed to its own locale and choosing is not on offer, so the screen says
    /// that rather than showing a list it cannot honour.
    static func supported() async -> [String] {
        guard #available(iOS 26.0, macOS 26.0, *) else { return [] }
        let locales = await SpeechTranscriber.supportedLocales
        var seen = Set<String>()
        return locales
            .map { $0.identifier(.bcp47) }
            .filter { seen.insert($0).inserted }
            .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// "es-ES" → "Spanish (Spain)". Falls back to the code, which is still more
    /// useful than a blank row.
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Which languages this PHONE listens for while you are speaking.
///
/// No longer required for anything to work, and the screen says so. The server
/// re-hears every utterance and detects its language from the audio across 100
/// of them (`webui/api/live_language.py`), so the saved transcript and its
/// translation come out right whatever is or is not chosen here.
///
/// What is left is the live preview. Apple's framework has one locale per
/// recogniser and no language-identification module, so the words appearing on
/// screen AS you speak come from whichever locales this phone was pointed at —
/// naming a language you use often makes that preview match instead of showing
/// the English spelling of it for a second. It is a comfort, not a correctness
/// requirement, and it costs one recogniser per language.
///
/// This list is Apple's `supportedLocales`, which is far shorter than the
/// server's 100. That gap is exactly why the server does the detecting.
struct LiveLanguagesScreen: View {
    let store: LiveStore

    @State private var chosen: [String] = []
    @State private var available: [String] = []
    @State private var query = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                explanation
                chosenSection
                addSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .jcScreen("Languages")
        .animation(.easeInOut(duration: 0.18), value: chosen)
        .task {
            chosen = store.settings.sttLanguages
            available = await LiveLanguageCatalog.supported()
            loaded = true
        }
    }

    // MARK: - Sections

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The headline, because the screen used to imply the opposite: a
            // language missing from this list was a language Live got wrong.
            Text("Jarvis detects the language by itself. Every recording is "
               + "re-heard on the server across 100 languages, so you do not "
               + "have to add anything here.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(chosen.isEmpty
                 ? "While you speak, the words on screen come from this phone "
                 + "listening in \(primaryName). Speak something else and they "
                 + "will look wrong for a moment, then correct themselves. Add "
                 + "a language below only to make that live preview match."
                 : "While you speak, this phone previews these, in order — the "
                 + "first is preferred. The saved transcript is corrected on "
                 + "the server either way.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if chosen.count > 1 {
                // The cost, plainly, at the moment it is being incurred. There is
                // no multi-language recogniser in the framework, so this is N
                // separate transcribers over the same audio.
                Text("\(chosen.count) languages means \(chosen.count) recognisers running on "
                   + "every utterance — about \(chosen.count)× the transcription work and "
                   + "battery of one.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loaded, !available.isEmpty {
                // Naming the number stops the list reading as the limit of what
                // Jarvis understands, which is what it looked like.
                Text("This phone can preview \(available.count) of them. The "
                   + "server understands 100.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loaded, available.isEmpty {
                Text("This phone's speech engine can't be pointed at a language, so the "
                   + "live preview uses the primary language. The saved transcript is "
                   + "still corrected on the server.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Affects the live preview only, from the next recording.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var chosenSection: some View {
        if !chosen.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Listening for")
                GlassGroup {
                    ForEach(Array(chosen.enumerated()), id: \.element) { index, code in
                        GlassRow(symbol: index == 0 ? "star" : "character.bubble",
                                 title: LiveLanguageCatalog.name(code),
                                 subtitle: index == 0 ? "\(code) · preferred" : code,
                                 last: index == chosen.count - 1) {
                            HStack(spacing: 14) {
                                if index > 0 {
                                    Button { promote(code) } label: {
                                        JcIcon("arrow.up", size: 14)
                                            .foregroundStyle(JcTheme.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Prefer \(LiveLanguageCatalog.name(code))")
                                }
                                Button { remove(code) } label: {
                                    JcIcon("minus.circle", size: 15)
                                        .foregroundStyle(JcTheme.danger)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Stop listening for "
                                                  + LiveLanguageCatalog.name(code))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var addSection: some View {
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel(chosen.count >= LiveSettings.maxLanguages
                                ? "That's the most Live will run at once"
                                : "Add a language")
                if chosen.count < LiveSettings.maxLanguages {
                    GlassGroup {
                        GlassRow(symbol: "magnifyingglass", title: "") {
                            TextField("Search", text: $query)
                                .font(JcText.body)
                                .foregroundStyle(JcTheme.text)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        let matches = filtered
                        ForEach(Array(matches.enumerated()), id: \.element) { index, code in
                            Button { add(code) } label: {
                                GlassRow(symbol: "plus",
                                         title: LiveLanguageCatalog.name(code),
                                         subtitle: code,
                                         last: index == matches.count - 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Plumbing

    private var primaryName: String {
        let primary = store.config.primaryLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? "the device language" : LiveLanguageCatalog.name(primary)
    }

    /// The catalogue is long (dozens of locales), so it is capped until the user
    /// narrows it — a list nobody can reach the bottom of is not a list.
    private var filtered: [String] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = available.filter { !chosen.contains($0) }
        guard !clean.isEmpty else { return Array(pool.prefix(12)) }
        return pool.filter {
            $0.localizedCaseInsensitiveContains(clean)
                || LiveLanguageCatalog.name($0).localizedCaseInsensitiveContains(clean)
        }
    }

    private func add(_ code: String) {
        guard chosen.count < LiveSettings.maxLanguages, !chosen.contains(code) else { return }
        chosen.append(code)
        query = ""
        persist()
    }

    private func remove(_ code: String) {
        chosen.removeAll { $0 == code }
        persist()
    }

    /// Move to the front. "Preferred" is not decoration: it is the language the
    /// in-progress line is shown from, and the tie-break when the recognisers
    /// report no confidence to choose between them.
    private func promote(_ code: String) {
        guard let index = chosen.firstIndex(of: code), index > 0 else { return }
        chosen.remove(at: index)
        chosen.insert(code, at: 0)
        persist()
    }

    private func persist() {
        store.settings.sttLanguages = chosen
        // Read back: the setter normalises (dedupe, cap), and the screen must
        // show what was actually stored rather than what was asked for.
        chosen = store.settings.sttLanguages
    }
}
