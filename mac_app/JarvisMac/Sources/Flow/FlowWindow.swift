import AppKit
import SwiftUI

/// The Flow window (menu bar → Flow… / Notes…): Dictation, Notes, Stats,
/// Dictionary, Snippets, Styles, Settings.
@MainActor
enum FlowWindow {
    enum Page: String, CaseIterable, Identifiable {
        case dictation, notes, stats, dictionary, snippets, styles, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: return String(localized: "Dictation")
            case .notes: return String(localized: "Notes")
            case .stats: return String(localized: "Stats")
            case .dictionary: return String(localized: "Dictionary")
            case .snippets: return String(localized: "Snippets")
            case .styles: return String(localized: "Styles")
            case .settings: return String(localized: "Settings")
            }
        }

        var symbol: String {
            switch self {
            case .dictation: return "waveform"
            case .notes: return "note.text"
            case .stats: return "chart.bar"
            case .dictionary: return "character.book.closed"
            case .snippets: return "text.badge.plus"
            case .styles: return "textformat"
            case .settings: return "gearshape"
            }
        }
    }

    @MainActor
    @Observable
    final class Router {
        var page: Page = .dictation
    }

    private static var window: NSWindow?
    private static let router = Router()

    static func show(_ page: Page? = nil) {
        if let page { router.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Jarvis Flow")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 520)
            w.contentView = NSHostingView(rootView: FlowRoot(router: router).tint(JcAccent.color))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct FlowRoot: View {
    @Bindable var router: FlowWindow.Router

    var body: some View {
        NavigationSplitView {
            List(FlowWindow.Page.allCases, selection: Binding(get: { router.page }, set: { if let p = $0 { router.page = p } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch router.page {
            case .dictation: DictationPage()
            case .notes: NotesPage()
            case .stats: StatsPage()
            case .dictionary: DictionaryPage()
            case .snippets: SnippetsPage()
            case .styles: StylesPage()
            case .settings: FlowSettings()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Dictation

private struct DictationPage: View {
    private var store: FlowStore { FlowStore.shared }
    private var flow: FlowDictation { FlowDictation.shared }
    @State private var search = ""
    @State private var tryIt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text("Try it here").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $tryIt)
                    .font(.system(size: 13))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Text("History").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if filtered.isEmpty {
                Spacer()
                Text(store.history.isEmpty ? "Your dictations show here." : "Nothing matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(group.day) {
                            ForEach(group.entries) { entry in EntryRow(entry: entry) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .navigationTitle("Dictation")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: flow.enabled ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 30)).foregroundStyle(flow.enabled ? JcAccent.color : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.enabled ? "Hold \(flow.key.label) to dictate" : "Flow dictation is off").font(.title3.weight(.semibold))
                Text(flow.enabled
                     ? "Tap it twice for hands-free. Esc cancels. ⌃⌘V pastes the last one again."
                     : "Turn it on to dictate into any app.")
                    .foregroundStyle(.secondary)
                if flow.enabled && !flow.trusted {
                    Button("Allow Accessibility so Jarvis can see the key and paste") {
                        flow.askForAccessibility()
                        flow.openAccessibilitySettings()
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { flow.enabled }, set: { flow.setEnabled($0) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.45)))
    }

    private var filtered: [FlowEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.app ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(day: String, entries: [FlowEntry])] {
        var out: [(day: String, entries: [FlowEntry])] = []
        for entry in filtered {
            let day = entry.date.formatted(date: .complete, time: .omitted)
            if out.last?.day == day { out[out.count - 1].entries.append(entry) } else { out.append((day, [entry])) }
        }
        return out
    }
}

private struct EntryRow: View {
    let entry: FlowEntry
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text).textSelection(.enabled)
                Text([entry.app, "\(entry.words) words"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hovering {
                Button { copy(entry.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button { FlowStore.shared.delete(entry) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete")
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Stats

private struct StatsPage: View {
    private var store: FlowStore { FlowStore.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    StatCard(value: FlowText.shortCount(store.stats.totalWords), label: "words dictated")
                    StatCard(value: "\(store.wordsPerMinute)", label: "words a minute")
                    StatCard(value: saved, label: "saved vs typing")
                    StatCard(value: "\(store.streak)", label: store.streak == 1 ? "day in a row" : "days in a row")
                    StatCard(value: FlowText.shortCount(store.stats.totalDictations), label: "dictations")
                    StatCard(value: "\(store.stats.apps.count)", label: store.stats.apps.count == 1 ? "app" : "apps")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last 14 days").font(.headline)
                    DayBars(days: store.dailyWords(last: 14))
                        .frame(height: 140)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.45)))
                if !topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where you dictate").font(.headline)
                        ForEach(topApps, id: \.name) { app in
                            HStack {
                                Text(app.name)
                                Spacer()
                                Text("\(app.words) words").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.45)))
                }
            }
            .padding(20)
        }
        .navigationTitle("Stats")
    }

    private var saved: String {
        let m = store.minutesSaved
        return m >= 60 ? String(format: "%.1f h", m / 60) : "\(Int(m.rounded())) min"
    }

    private var topApps: [(name: String, words: Int)] {
        store.stats.apps.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
    }
}

private struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.45)))
    }
}

private struct DayBars: View {
    let days: [(date: Date, words: Int)]

    var body: some View {
        let top = max(1, days.map(\.words).max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days, id: \.date) { day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(day.words > 0 ? JcAccent.color : Color.secondary.opacity(0.2))
                        .frame(height: max(3, CGFloat(day.words) / CGFloat(top) * 110))
                        .help("\(day.words) words")
                    Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words dictated each day for the last two weeks")
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    private var store: FlowStore { FlowStore.shared }
    @State private var word = ""
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("A name or word, spelt your way (Supabase, Pranav…)", text: $word)
                        .onSubmit(addWord)
                    Button("Add", action: addWord).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(store.words, id: \.self) { w in
                    HStack {
                        Text(w)
                        Spacer()
                        Button { store.words.removeAll { $0 == w } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Words")
            } footer: {
                Text("Written exactly like this, and given to the recognizer as hints.").font(.caption)
            }
            Section {
                HStack {
                    TextField("Heard", text: $from)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Written", text: $to).onSubmit(addReplacement)
                    Button("Add", action: addReplacement).disabled(from.isEmpty || to.isEmpty)
                }
                ForEach(store.replacements) { r in
                    HStack {
                        Text(r.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r.to).fontWeight(.medium)
                        Spacer()
                        Button { store.replacements.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("“cloud code” → “Claude Code”. Whole words only, any case.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictionary")
    }

    private func addWord() {
        store.addWord(word)
        word = ""
    }

    private func addReplacement() {
        store.addReplacement(from: from, to: to)
        from = ""
        to = ""
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    private var store: FlowStore { FlowStore.shared }
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField("Say this (“my address”)", text: $trigger)
                TextEditor(text: $text).frame(height: 70).font(.system(size: 13))
                Button("Add the snippet") {
                    store.addSnippet(trigger: trigger, text: text)
                    trigger = ""
                    text = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
            } header: {
                Text("New snippet")
            } footer: {
                Text("Say the trigger in a dictation and the whole text goes in its place, exactly as written.").font(.caption)
            }
            Section("Snippets") {
                if store.snippets.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(store.snippets) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("“\(s.trigger)”").fontWeight(.medium)
                            Text(s.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button { store.snippets.removeAll { $0.id == s.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Snippets")
    }
}

// MARK: - Styles

private struct StylesPage: View {
    private var store: FlowStore { FlowStore.shared }
    @State private var defaultStyle = Prefs.flowDefaultStyle

    var body: some View {
        Form {
            Section {
                Picker("Every other app", selection: $defaultStyle) {
                    ForEach(FlowStyle.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: defaultStyle) { _, v in Prefs.flowDefaultStyle = v }
                Text(defaultStyle.detail).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Default")
            } footer: {
                Text(Prefs.flowCleanup ? "Styles apply when the clean-up is on (it is)."
                                       : "Styles apply when the clean-up is on (Settings → Words).").font(.caption)
            }
            Section("Apps") {
                ForEach(store.appStyles) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Picker("", selection: Binding(get: { app.style },
                                                      set: { store.setStyle($0, bundleID: app.bundleID, name: app.name) })) {
                            ForEach(FlowStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        Button { store.appStyles.removeAll { $0.bundleID == app.bundleID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add a running app") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) { store.setStyle(defaultStyle, bundleID: app.bundleID, name: app.name) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Styles")
    }

    private var runningApps: [(bundleID: String, name: String)] {
        let known = Set(store.appStyles.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !known.contains(id), id != Bundle.main.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
