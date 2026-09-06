import SwiftUI

/// The `jarvis_memory` semantic store — the same data the webui "Long-term
/// memory" panel renders. Ported from `long_term_memory_page.dart`.
///
/// Stats header + namespace chips, a debounced semantic search box over a
/// deletable results list, and the Reflections section (run / dismiss). When the
/// store isn't initialised the server fail-softs to `{available:false, error:…}`
/// and we render the unavailable card instead of an empty screen.
struct LongTermMemoryPage: View {
    @State private var store: JarvisMemoryStore
    /// The text field's own state: `store.query` is updated through
    /// `queryChanged`, which also drives the debounce, so binding straight to it
    /// would set it twice per keystroke.
    @State private var query = ""
    @State private var pendingDelete: MemoryEntry?

    init(store: JarvisMemoryStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { JarvisMemoryStore() })
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
                loaded
            }
        }
        .jcScreen("Long-term memory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "arrow.clockwise", size: 34, iconSize: 16) {
                    store.reload()
                }
            }
        }
        .task { if !store.hasLoaded { store.onAppear() } }
        .moreToast($store.toast)
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
                searchBox.padding(.bottom, 12)
                results
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
                    Image(systemName: "brain")
                        .font(.system(size: 22))
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(JcTheme.muted)
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(JcTheme.muted)
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

    // MARK: Unavailable

    private var unavailable: some View {
        GlassCard(padding: 20) {
            VStack(spacing: 0) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 26))
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
        GlassCard(padding: 0, blur: false, fill: JcTheme.surface) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.body)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if !meta.isEmpty {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
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
                        Image(systemName: "trash")
                            .font(.system(size: 15))
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
        GlassCard(padding: 0, blur: false, fill: JcTheme.surface) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14)).foregroundStyle(JcTheme.accent)
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
            Image(systemName: symbol)
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
