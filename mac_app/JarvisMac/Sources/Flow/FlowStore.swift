import Foundation
import Observation

/// Everything the Flow window shows and edits: the history, the numbers, the
/// dictionary, the snippets and the styles. Small JSON files in
/// ~/Library/Application Support/Jarvis/Flow, on this Mac only.
/// After coucou's FlowStore (github.com/Louis-CFM/coucou, MIT).
@MainActor
@Observable
final class FlowStore {
    static let shared = FlowStore()

    /// Newest first.
    private(set) var history: [FlowEntry] = []
    private(set) var stats = FlowStats()
    var words: [String] = [] { didSet { saveWords() } }
    var replacements: [FlowReplacement] = [] { didSet { saveWords() } }
    var snippets: [FlowSnippet] = [] { didSet { save(snippets, to: "snippets.json") } }
    var appStyles: [FlowAppStyle] = [] { didSet { save(appStyles, to: "styles.json") } }

    /// Days the history is kept: 0 = not kept, -1 = forever.
    var keepDays: Int = Prefs.flowKeepDays {
        didSet {
            Prefs.flowKeepDays = keepDays
            prune()
        }
    }

    @ObservationIgnored private var loading = false
    /// When the history is not kept, the last dictation still waits here (memory only) for ⌃⌘V.
    @ObservationIgnored private var lastUnkeptText: String?

    private struct WordsFile: Codable {
        var words: [String]
        var replacements: [FlowReplacement]
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jarvis/Flow", isDirectory: true)
    }

    private init() {
        loading = true
        history = load([FlowEntry].self, from: "history.json") ?? []
        stats = load(FlowStats.self, from: "stats.json") ?? FlowStats()
        if let file = load(WordsFile.self, from: "words.json") {
            words = file.words
            replacements = file.replacements
        }
        snippets = load([FlowSnippet].self, from: "snippets.json") ?? []
        appStyles = load([FlowAppStyle].self, from: "styles.json") ?? FlowAppStyle.defaults
        loading = false
        if !Prefs.flowCodeAppsCleaned {
            // Once: code and AI apps left on the old "as said" default get the clean-up.
            appStyles = FlowAppStyle.migratingCodeApps(appStyles)
            Prefs.flowCodeAppsCleaned = true
        }
        prune()
    }

    // MARK: dictation

    func prepare(_ raw: String) -> FlowText.Prepared {
        FlowText.prepare(raw, words: words, replacements: replacements, snippets: snippets)
    }

    func style(for bundleID: String?) -> FlowStyle {
        FlowStyle.resolve(bundleID: bundleID, in: appStyles, default: Prefs.flowDefaultStyle)
    }

    var lastText: String? { history.first?.text ?? lastUnkeptText }

    func record(text: String, app: String?, seconds: Double) {
        let count = FlowText.wordCount(text)
        guard count > 0 else { return }
        let now = Date()
        stats.add(words: count, seconds: seconds, app: app, day: FlowText.dayKey(now))
        save(stats, to: "stats.json")
        lastUnkeptText = text
        guard keepDays != 0 else { return }
        history.insert(FlowEntry(date: now, text: text, app: app, words: count, seconds: seconds), at: 0)
        prune()
        saveHistory()
    }

    func delete(_ entry: FlowEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    /// Empties the history; the numbers stay.
    func clearHistory() {
        history = []
        lastUnkeptText = nil
        saveHistory()
    }

    /// Empties the history and the numbers.
    func clearEverything() {
        clearHistory()
        stats = FlowStats()
        save(stats, to: "stats.json")
    }

    private func prune() {
        guard !loading else { return }
        let kept = FlowHistory.pruned(history, keepDays: keepDays)
        if kept.count != history.count {
            history = kept
            saveHistory()
        }
    }

    // MARK: dictionary and snippets

    func addWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        words.append(w)
    }

    func addReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return }
        var next = replacements.filter { $0.from.caseInsensitiveCompare(f) != .orderedSame }
        next.append(FlowReplacement(from: f, to: t))
        replacements = next
    }

    func addSnippet(trigger: String, text: String) {
        let tr = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tr.isEmpty, !text.isEmpty else { return }
        var next = snippets.filter { $0.trigger.caseInsensitiveCompare(tr) != .orderedSame }
        next.append(FlowSnippet(trigger: tr, text: text))
        snippets = next
    }

    func setStyle(_ style: FlowStyle, bundleID: String, name: String) {
        var next = appStyles.filter { $0.bundleID != bundleID }
        next.append(FlowAppStyle(bundleID: bundleID, name: name, style: style))
        appStyles = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: numbers

    var wordsPerMinute: Int { FlowText.wordsPerMinute(words: stats.totalWords, seconds: stats.totalSeconds) }
    var minutesSaved: Double { FlowText.minutesSaved(words: stats.totalWords, seconds: stats.totalSeconds) }
    var streak: Int { FlowText.streak(days: Set(stats.days.filter { $0.value.words > 0 }.keys), today: Date()) }

    /// The words of the last `count` days, oldest first.
    func dailyWords(last count: Int) -> [(date: Date, words: Int)] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, stats.days[FlowText.dayKey(day)]?.words ?? 0)
        }
    }

    // MARK: files

    private func saveHistory() { save(history, to: "history.json") }
    private func saveWords() { save(WordsFile(words: words, replacements: replacements), to: "words.json") }

    private func save<T: Encodable>(_ value: T, to name: String) {
        guard !loading else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: Self.folder.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("Jarvis Flow: could not save \(name): \(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
