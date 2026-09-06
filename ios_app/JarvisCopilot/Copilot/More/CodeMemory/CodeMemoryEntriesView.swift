import SwiftUI

/// One repo's code memory: a Knowledge / Handoffs switch over two independent
/// entry lists. Both child stores are built once so switching tabs keeps each
/// list's search and results (Flutter's `TabBarView` did the same).
struct CodeMemoryProjectPage: View {
    let project: CodeMemoryProject
    @State private var knowledge: CodeMemoryEntriesStore
    @State private var handoffs: CodeMemoryEntriesStore
    /// Re-read the overview's counts after a mutation in either list.
    let onChanged: () -> Void

    @State private var kind: CodeMemoryKind = .knowledge

    init(project: CodeMemoryProject,
         knowledge: CodeMemoryEntriesStore,
         handoffs: CodeMemoryEntriesStore,
         onChanged: @escaping () -> Void) {
        self.project = project
        _knowledge = State(initialValue: knowledge)
        _handoffs = State(initialValue: handoffs)
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(CodeMemoryKind.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Both lists stay mounted so each keeps its search box and results.
            ZStack {
                CodeMemoryEntriesView(store: knowledge, onChanged: onChanged)
                    .opacity(kind == .knowledge ? 1 : 0)
                    .allowsHitTesting(kind == .knowledge)
                CodeMemoryEntriesView(store: handoffs, onChanged: onChanged)
                    .opacity(kind == .sessions ? 1 : 0)
                    .allowsHitTesting(kind == .sessions)
            }
        }
        .jcScreen(project.title)
    }
}

/// A searchable list of one project's entries of a single kind, with the detail
/// sheet, the edit form and the delete confirmation.
struct CodeMemoryEntriesView: View {
    @State var store: CodeMemoryEntriesStore
    let onChanged: () -> Void

    @State private var opened: CodeMemoryEntry?
    @State private var editing: CodeMemoryEntry?
    @State private var pendingDelete: CodeMemoryEntry?

    private var tone: Color { store.kind == .sessions ? JcTheme.accent : JcTheme.cyan }
    private var symbol: String { store.kind == .sessions ? "book.closed" : "lightbulb" }

    var body: some View {
        VStack(spacing: 0) {
            CodeMemorySearchField(
                text: $store.query,
                hint: store.kind == .sessions ? "Search handoffs…" : "Search knowledge…",
                onSubmit: { store.load() },
                // Clearing must restore the full list without a submit.
                onClear: { store.load() })
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 10) {
                    list
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh() }
            .scrollDismissesKeyboard(.interactively)
        }
        .loadErrorBanner(store.errorMessage, hasContent: !store.entries.isEmpty)
        .task { if !store.hasLoaded { store.load() } }
        .moreToast($store.toast)
        .sheet(item: $opened) { entry in
            detailSheet(entry)
        }
        .sheet(item: $editing) { entry in
            CodeMemoryEditSheet(entry: entry) { text in
                let ok = await store.update(entry, content: text)
                if ok { onChanged() }
                return ok
            }
        }
        .alert("Delete entry?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    let ok = await store.delete(entry)
                    if ok { onChanged() }
                }
            }
        } message: { _ in
            Text("This permanently removes this entry. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var list: some View {
        if let message = store.errorMessage, store.entries.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 60)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if store.entries.isEmpty {
            CodeMemoryEmptyState(
                symbol: store.query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? symbol : "magnifyingglass",
                message: emptyMessage)
                .padding(.top, 60)
        } else {
            ForEach(Array(store.entries.enumerated()), id: \.offset) { _, entry in
                Button { opened = entry } label: {
                    CodeMemoryEntryRow(entry: entry, kind: store.kind,
                                       symbol: symbol, tone: tone)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyMessage: String {
        if !store.query.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches." }
        return store.kind == .sessions ? "No session handoffs yet." : "No knowledge stored yet."
    }

    private func detailSheet(_ entry: CodeMemoryEntry) -> some View {
        let type = entry.entryType.isEmpty ? store.kind.defaultEntryType : entry.entryType
        let body = entry.content.isEmpty ? entry.firstLine : entry.content
        return DetailSheet(title: type) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StatusPill(type, color: tone, dense: true)
                    let ts = entry.tsLabel()
                    if !ts.isEmpty {
                        Image(systemName: "clock")
                            .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                        Text(ts).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                }
                Text(body.isEmpty ? "(empty)" : body)
                    .font(.system(size: 14.5))
                    .foregroundStyle(JcTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(JcTheme.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } actions: {
            GlassButton(title: "Edit", symbol: "square.and.pencil", ghost: true) {
                opened = nil
                editing = entry
            }
            GlassButton(title: "Delete", symbol: "trash", ghost: true) {
                opened = nil
                pendingDelete = entry
            }
        }
    }
}

/// One entry: its first line, the entry-type pill and the relative timestamp.
struct CodeMemoryEntryRow: View {
    let entry: CodeMemoryEntry
    let kind: CodeMemoryKind
    let symbol: String
    let tone: Color

    var body: some View {
        GlassCard(padding: 0, blur: false) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tone)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.title(kind: kind))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) {
                        StatusPill(entry.entryType.isEmpty ? kind.defaultEntryType
                                                           : entry.entryType,
                                   color: tone, dense: true)
                        Spacer(minLength: 8)
                        let ts = entry.tsLabel()
                        if !ts.isEmpty {
                            Text(ts).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 13)
        }
    }
}

/// The edit form. Its own `@State` draft so the sheet can be cancelled without
/// touching the store.
struct CodeMemoryEditSheet: View {
    let entry: CodeMemoryEntry
    let onSave: (String) async -> Bool

    @State private var text: String

    init(entry: CodeMemoryEntry, onSave: @escaping (String) async -> Bool) {
        self.entry = entry
        self.onSave = onSave
        _text = State(initialValue: entry.content)
    }

    var body: some View {
        FormSheet(title: "Edit entry", onSave: { await onSave(text) }) {
            FormTextField(label: "Content", text: $text, lineLimit: 12)
        }
    }
}
