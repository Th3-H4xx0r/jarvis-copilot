import SwiftUI

/// The `jarvis_memory` semantic store — the same data the webui "Long-term
/// memory" panel renders. Ported from `long_term_memory_page.dart`.
///
/// Stats header + namespace chips, the memory model and the Cleanup card, a
/// debounced semantic search box over a deletable results list, and the
/// Reflections section (run / dismiss). When the
/// store isn't initialised the server fail-softs to `{available:false, error:…}`
/// and we render the unavailable card instead of an empty screen.
struct LongTermMemoryPage: View {
    @State private var store: JarvisMemoryStore
    @State private var map: MemoryMapStore
    /// The memory map (Map mode): its own store, loaded the first time Map shows.
    @State private var graph: MemoryGraphStore
    @State private var mode: MemoryPageMode = .map
    /// Re-read on every appear: Settings can change it while the page is away.
    @State private var remindersUnasked = false
    @State private var expanded: Set<String> = []
    @State private var confirmingCleanup = false
    @Environment(\.scenePhase) private var scenePhase
    /// The text field's own state: `store.query` is updated through
    /// `queryChanged`, which also drives the debounce, so binding straight to it
    /// would set it twice per keystroke.
    @State private var query = ""
    @State private var pendingDelete: MemoryEntry?

    init(store: JarvisMemoryStore? = nil, map: MemoryMapStore? = nil, graph: MemoryGraphStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { JarvisMemoryStore() })
        _map = State(initialValue: map ?? MainActor.assumeIsolated { MemoryMapStore() })
        _graph = State(initialValue: graph ?? MainActor.assumeIsolated { MemoryGraphStore() })
    }

    var body: some View {
        Group {
            if !store.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = store.errorMessage {
                // The header request itself failed. `available` still reads true
                // here (it only goes false on an explicit `available: false`
                // payload), so this branch must not be gated on it.
                CenteredMessage(text: message, color: JcTheme.danger) { store.reload() }
            } else if !store.available {
                ScrollView { unavailable.padding(.horizontal, 16).padding(.top, 64) }
                    .refreshable { await store.refresh() }
            } else {
                VStack(spacing: 0) {
                    JcSegmented(items: MemoryPageMode.allCases, selection: $mode,
                                label: { $0.label }, symbol: { $0.symbol })
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    if mode == .map {
                        MemoryMapScreen(store: graph)
                    } else {
                        loaded
                    }
                }
            }
        }
        .jcScreen("Long-term memory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "arrow.clockwise", size: 34, iconSize: 16) {
                    if mode == .map {
                        Task { await graph.load() }
                    } else {
                        store.reload()
                    }
                }
            }
        }
        .task { if !store.hasLoaded { store.onAppear() } }
        .onAppear {
            map.appeared()
            remindersUnasked = RemindersAccess.notDetermined
        }
        .onDisappear { map.disappeared() }
        // Locked or in the background: no 3 s cleanup poll.
        .onChange(of: scenePhase) { _, phase in map.setActive(phase == .active) }
        .confirmationDialog("Run cleanup?", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("Run cleanup") { Task { await map.runCleanup() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It backs up your memory, then reads every memory once with your memory model "
                 + "— a one-time cost on your API key.")
        }
        .moreToast($store.toast)
        .moreToast($map.toast)
        .alert("Forget this memory?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                Task { await store.deleteEntry(entry.id) }
            }
        } message: { _ in
            Text("This removes the entry from the long-term store and cannot be undone.")
        }
    }

    // MARK: Loaded

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statsHeader.padding(.bottom, 16)
                if let settings = map.settings {
                    memoryModel(settings).padding(.bottom, 20)
                }
                if let cleanup = map.cleanup {
                    cleanupSection(cleanup).padding(.bottom, 20)
                }
                searchBox.padding(.bottom, 12)
                results
                if !store.recalls.isEmpty {
                    recentRecalls.padding(.top, 24)
                }
                reflections.padding(.top, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await store.refresh() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var statsHeader: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    JcIcon("brain", size: 22)
                        .foregroundStyle(JcTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(JcTheme.accent.opacity(0.14), in: Circle())
                        .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.data.count)")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(JcTheme.text)
                        Text("memories stored")
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                if !store.namespaces.isEmpty {
                    Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                        .padding(.vertical, 14)
                    JcWrap(spacing: 8, runSpacing: 8) {
                        ForEach(store.namespaces) { ns in
                            MemoryNamespaceChip(name: ns.namespace, count: ns.count)
                        }
                    }
                }
            }
        }
    }

    private var searchBox: some View {
        HStack(spacing: 10) {
            JcIcon("magnifyingglass", size: 15).foregroundStyle(JcTheme.muted)
            TextField("Search your long-term memory…", text: $query)
                .font(JcText.body)
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: query) { _, new in store.queryChanged(new) }
                .onSubmit { store.runSearch(query) }
            if store.isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    store.runSearch("")
                } label: {
                    JcIcon("xmark.circle.fill", size: 15).foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(JcTheme.glassFill,
                    in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var results: some View {
        if store.results.isEmpty {
            // An empty query returns the store's recent entries, so nothing back
            // genuinely means "nothing captured" rather than "not searched yet".
            MemorySectionEmpty(
                symbol: store.lastQuery.isEmpty ? "shippingbox" : "magnifyingglass",
                message: store.lastQuery.isEmpty
                    ? "No memories captured yet."
                    : "No memories match “\(store.lastQuery)”.")
                .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(store.lastQuery.isEmpty ? "Recent" : "Results") {
                    StatusPill("\(store.results.count)", color: JcTheme.cyan, dense: true)
                }
                ForEach(store.results) { entry in
                    MemoryEntryCard(entry: entry) { pendingDelete = entry }
                        .padding(.bottom, 10)
                }
            }
        }
    }

    /// Turns where Jarvis drew on memory. Tap one → the map, lit up on what it used.
    private var recentRecalls: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Recent recalls") {
                StatusPill("\(store.recalls.count)", color: JcTheme.accent, dense: true)
            }
            GlassCard(padding: 0, fill: JcTheme.surface) {
                VStack(spacing: 0) {
                    ForEach(Array(store.recalls.prefix(12).enumerated()), id: \.element.id) { index, recall in
                        if index > 0 {
                            Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 14)
                        }
                        Button {
                            mode = .map
                            Task { await graph.showRecall(recall) }
                        } label: {
                            MemoryRecallRow(recall: recall)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var reflections: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Reflections") {
                if !store.reflections.isEmpty {
                    StatusPill("\(store.reflections.count)", color: JcTheme.accent, dense: true)
                }
            }
            GlassButton(title: "Run reflection", symbol: "sparkles", ghost: true, full: true) {
                Task { await store.runReflections() }
            }
            .padding(.top, 4)
            .padding(.bottom, 14)

            if store.reflections.isEmpty {
                MemorySectionEmpty(symbol: "sparkles",
                                   message: "No insights yet — they appear as Jarvis "
                                          + "reviews your memory.")
            } else {
                ForEach(store.reflections) { reflection in
                    MemoryReflectionCard(reflection: reflection) {
                        Task { await store.dismissReflection(reflection.id) }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: Memory model

    private func memoryModel(_ settings: MemoryMapSettings) -> some View {
        let pick = AgentPick(settings.agent)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Memory model")
            NavigationLink {
                AgentChoicePage(title: "Memory model", pick: pick) { pick in
                    Task { await map.setAgent(pick.choice) }
                }
            } label: {
                GlassCard(padding: 0, fill: JcTheme.surface) {
                    HStack(spacing: 10) {
                        Text("Runs on").font(.system(size: 15)).foregroundStyle(JcTheme.text)
                        Spacer(minLength: 8)
                        Text(settings.label.isEmpty ? pick.label : settings.label)
                            .font(.system(size: 14))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                        JcIcon("chevron.right", size: 11).foregroundStyle(JcTheme.muted.opacity(0.6))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            Text("Reads chats, iMessage and Live to pull out dates, people and places.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            if remindersUnasked {
                GlassButton(title: "Let Jarvis see Reminders", symbol: "checklist", ghost: true, full: true) {
                    Task {
                        // Asked on the snapshot's own store, which then sends them.
                        _ = await ContextSnapshot.shared.requestRemindersAccess()
                        remindersUnasked = RemindersAccess.notDetermined
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: Cleanup

    private func cleanupSection(_ cleanup: MemoryCleanupStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Cleanup & map") {
                if cleanup.running {
                    StatusPill(cleanup.stopping ? "Stopping" : "Running", color: JcTheme.accent,
                               live: true, dense: true)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    if cleanup.running {
                        // A run from anywhere — this phone, the web, or the server's backfill.
                        cleanupProgress(cleanup.progress)
                        Button {
                            Task { await map.stopCleanup() }
                        } label: {
                            HStack(spacing: 6) {
                                if map.requestingStop || cleanup.stopping {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    JcIcon("stop.fill", size: 12)
                                }
                                Text(cleanup.stopTitle)
                            }
                        }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                        .disabled(!cleanup.canStop || map.requestingStop)
                    } else {
                        if let error = cleanup.error {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(JcTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let report = cleanup.report {
                            cleanupReport(report)
                        }
                        GradientButton(cleanup.runTitle, symbol: "wand.and.stars", busy: map.startingCleanup,
                                       full: true) {
                            confirmingCleanup = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("One-time tidy-up: backs up, merges duplicates, fixes times, then maps older memories to "
                 + "dates, people and places. New memories are mapped automatically — you don't need to "
                 + "run this again.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    private func cleanupProgress(_ progress: MemoryCleanupProgress?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress?.line ?? "Starting…")
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundStyle(JcTheme.text)
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .tint(JcTheme.accent)
                    .animation(.easeOut(duration: 0.4), value: fraction)
            } else {
                ProgressView().tint(JcTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cleanupReport(_ report: MemoryCleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let finished = report.finishedAt {
                Text("Last run \(RelativeTime.format(finished))")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            JcWrap(spacing: 8, runSpacing: 8) {
                ForEach(report.counts) { count in
                    MemoryNamespaceChip(name: count.label, count: count.value)
                }
            }
            ForEach(report.examples) { group in
                cleanupExamples(group)
            }
        }
    }

    private func cleanupExamples(_ group: MemoryCleanupExamples) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) },
                                            set: { open in
                                                if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
                                            })) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.body)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if group.kind.restorable {
                            let done = map.restored.contains(item.id)
                            Button(done ? "Restored" : "Restore") {
                                Task { await map.restore(item.id) }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(done ? JcTheme.muted : JcTheme.accent)
                            .buttonStyle(.plain)
                            .disabled(done)
                            .frame(minHeight: 32)
                        }
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("\(group.kind.label) · \(group.items.count)")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(JcTheme.text)
        }
        .tint(JcTheme.muted)
    }

    // MARK: Unavailable

    private var unavailable: some View {
        GlassCard(padding: 20) {
            VStack(spacing: 0) {
                JcIcon("icloud.slash", size: 26)
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 64, height: 64)
                    .background(JcTheme.muted.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                Text("Memory store unavailable")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .padding(.bottom, 10)
                Text(store.unavailableMessage
                     ?? "The jarvis_memory store isn’t initialized yet. Run memory setup "
                      + "and choose jarvis_memory, then chat — turns are captured "
                      + "automatically and become searchable here.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
                GlassButton(title: "Retry", symbol: "arrow.clockwise", ghost: true) {
                    store.reload()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Rows

/// Map or List at the top of Long-term memory.
enum MemoryPageMode: String, CaseIterable, Identifiable, Hashable {
    case map, list
    var id: String { rawValue }
    var label: String { self == .map ? "Map" : "List" }
    var symbol: String { self == .map ? "point.3.connected.trianglepath.dotted" : "list.bullet" }
}

/// One recall: the question, when, and how many memories it used.
struct MemoryRecallRow: View {
    let recall: MemoryRecall

    var body: some View {
        HStack(spacing: 12) {
            JcIcon("brain", size: 14).foregroundStyle(JcTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(recall.title)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let when = recall.ts.map { RelativeTime.format($0) } ?? ""
                let used = recall.memoryIDs.count == 1 ? "1 memory" : "\(recall.memoryIDs.count) memories"
                Text([when, used].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
            }
            JcIcon("chevron.right", size: 11).foregroundStyle(JcTheme.muted.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// A namespace bucket: its name plus a tinted count badge.
struct MemoryNamespaceChip: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text("\(count)")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.white.opacity(0.045), in: Capsule())
    }
}

/// One search hit: the body, its source/namespace/age meta line, the similarity
/// score and a Forget button.
struct MemoryEntryCard: View {
    let entry: MemoryEntry
    let onDelete: () -> Void

    /// "chat · personal · 5m ago". `createdLabel` is an addition over the Flutter
    /// card — the store already computes it and an undated memory reads oddly.
    private var meta: String {
        [entry.source, entry.namespace, entry.createdLabel()]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        GlassCard(padding: 0, fill: JcTheme.surface) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.body)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if !meta.isEmpty {
                        JcIcon("tag", size: 11)
                            .foregroundStyle(JcTheme.muted.opacity(0.8))
                        Text(meta)
                            .font(.system(size: 11.5))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let score = entry.score {
                        StatusPill(String(format: "%.2f", score), color: JcTheme.cyan, dense: true)
                    }
                    Button(action: onDelete) {
                        JcIcon("trash", size: 15)
                            .foregroundStyle(JcTheme.danger)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Forget")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 13)
            .padding(.bottom, 11)
        }
    }
}

/// One proactive insight, with its kind badge and a Dismiss action.
struct MemoryReflectionCard: View {
    let reflection: MemoryReflection
    let onDismiss: () -> Void

    private var title: String {
        reflection.title.isEmpty ? reflection.body : reflection.title
    }
    private var showsBody: Bool {
        !reflection.body.isEmpty && reflection.body != title
    }

    var body: some View {
        GlassCard(padding: 0, fill: JcTheme.surface) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    JcIcon("sparkles", size: 14).foregroundStyle(JcTheme.accent)
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !reflection.kind.isEmpty {
                        StatusPill(reflection.kind, color: JcTheme.accent, dense: true)
                    }
                    Button("Dismiss", action: onDismiss)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                }
                if showsBody {
                    Text(reflection.body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .padding(.leading, 24)
                        .padding(.trailing, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 13)
        }
    }
}

/// A compact in-list empty state: a soft glyph above a muted message.
struct MemorySectionEmpty: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            JcIcon(symbol)
                .font(.system(size: 26))
                .foregroundStyle(JcTheme.muted.opacity(0.7))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
