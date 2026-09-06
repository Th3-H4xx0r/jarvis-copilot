import SwiftUI

/// Viewer/editor for the agent's long-term memory files — MEMORY.md ("My Notes")
/// and USER.md ("User Profile"). Ported from `memory_page.dart`: a section
/// toggle, the selected file as monospaced selectable text with its last-modified
/// chip, and a full-screen editor that writes back through `/api/memory/write`.
struct MemoryPage: View {
    @State private var store: MemoryStore
    @State private var editing = false

    init(store: MemoryStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { MemoryStore() })
    }

    var body: some View {
        VStack(spacing: 0) {
            MemorySectionToggle(section: $store.section)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView {
                content.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .refreshable { await store.refresh() }
        }
        .loadErrorBanner(store.errorMessage, hasContent: !store.documents.isEmpty)
        .jcScreen("Memory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "square.and.pencil", size: 34, iconSize: 16,
                                tint: store.canEdit ? JcTheme.text : JcTheme.muted.opacity(0.5)) {
                    if store.canEdit { editing = true }
                }
            }
        }
        .task { if !store.hasLoaded { store.load() } }
        .sheet(isPresented: $editing) {
            MemoryEditorView(title: store.section.label,
                             initialContent: store.content,
                             isSaving: store.isSaving,
                             saveError: store.errorMessage) { text in
                await store.save(text)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage, !store.hasLoaded || store.documents.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 100)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if store.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MemoryEmptyState(symbol: store.section.iconName,
                             text: store.section.emptyText,
                             hint: store.section.emptyHint)
                .padding(.top, 100)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !store.mtimeLabel.isEmpty { MemoryMtimeChip(mtime: store.mtimeLabel) }
                GlassCard(padding: 16, blur: false, fill: JcTheme.surface) {
                    Text(store.content)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The My Notes / User Profile segmented control: one rounded track, the
/// selected segment tinted with the brand accent.
struct MemorySectionToggle: View {
    @Binding var section: MemorySection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MemorySection.allCases) { item in
                Button { section = item } label: {
                    MemorySegmentTab(symbol: item.iconName, label: item.label,
                                     selected: item == section)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        .background(JcTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

struct MemorySegmentTab: View {
    let symbol: String
    let label: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if selected {
                shape.fill(JcTheme.accent.opacity(0.28))
                    .overlay(shape.strokeBorder(JcTheme.accent.opacity(0.45), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

/// The "Last edited …" pill above the content card.
struct MemoryMtimeChip: View {
    let mtime: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(JcTheme.muted)
            Text("Last edited \(mtime)").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

struct MemoryEmptyState: View {
    let symbol: String
    let text: String
    let hint: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 64, height: 64)
                .background(JcTheme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                .padding(.bottom, 16)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .padding(.bottom, 6)
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
}

/// Full-screen Markdown editor for one memory section. Confirms before
/// discarding unsaved edits, exactly as the Flutter `PopScope` guard did.
struct MemoryEditorView: View {
    let title: String
    let initialContent: String
    var isSaving: Bool
    /// Why the last save failed, from the store. The editor stays open on a
    /// failure, and without this the only feedback was the sheet not closing —
    /// indistinguishable from a tap that missed the button.
    var saveError: String?
    /// Returns true when the write stuck; false leaves the editor open.
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var confirmDiscard = false
    /// Set when THIS editor's save came back false, so a stale store error from
    /// an earlier load doesn't accuse the user of a failed write.
    @State private var failed = false

    init(title: String, initialContent: String, isSaving: Bool = false,
         saveError: String? = nil,
         onSave: @escaping (String) async -> Bool) {
        self.title = title
        self.initialContent = initialContent
        self.isSaving = isSaving
        self.saveError = saveError
        self.onSave = onSave
        _text = State(initialValue: initialContent)
    }

    /// The line to show above the Save button, or nil.
    var visibleSaveError: String? {
        guard failed else { return nil }
        let message = saveError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Couldn't save. Try again." : message
    }

    private var dirty: Bool { text != initialContent }
    private var busy: Bool { saving || isSaving }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    Text("Markdown supported")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    Spacer(minLength: 8)
                    if dirty { StatusPill("UNSAVED", color: JcTheme.accentAlt, dense: true) }
                }
                .padding(.bottom, 10)

                GlassCard(padding: 14, blur: false, fill: JcTheme.surface) {
                    TextEditor(text: $text)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                if let visibleSaveError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text(visibleSaveError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.danger)
                    .padding(.top, 10)
                }

                GradientButton("Save", symbol: "square.and.arrow.down",
                               busy: busy, full: true) { save() }
                    .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .jcScreen("Edit \(title)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { close() }
                        .font(JcText.label).foregroundStyle(JcTheme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(symbol: "checkmark", size: 34, iconSize: 16,
                                    tint: JcTheme.success) { save() }
                        .disabled(busy)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(dirty)
        .alert("Discard changes?", isPresented: $confirmDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Your edits to this section have not been saved.")
        }
    }

    private func close() {
        if dirty { confirmDiscard = true } else { dismiss() }
    }

    private func save() {
        guard !busy else { return }
        saving = true
        failed = false
        Task {
            let ok = await onSave(text)
            saving = false
            failed = !ok
            if ok { dismiss() }
        }
    }
}
