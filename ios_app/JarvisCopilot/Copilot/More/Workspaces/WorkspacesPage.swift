import SwiftUI

/// The "Workspaces" screen, ported from `pages/more/workspaces_page.dart`.
///
/// The agent's registered workspace folders as a drag-to-reorder list, each with
/// its friendly name, absolute path and a "last used" badge on the most recent
/// one. `+` adds a folder by path (with live suggestions); each row's menu
/// renames or removes it.
struct WorkspacesPage: View {
    @State private var store: WorkspacesStore
    @State private var adding = false
    @State private var renaming: Workspace?
    @State private var removing: Workspace?

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: WorkspacesStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { WorkspacesStore() })
    }

    var body: some View {
        content
            .loadErrorBanner(store.errorMessage, hasContent: !store.workspaces.isEmpty)
            .jcScreen("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add workspace")
                }
            }
            .task { if store.workspaces.isEmpty { store.load() } }
            .moreToast($store.toast)
            .sheet(isPresented: $adding) {
                WorkspaceAddSheet(store: store)
            }
            .sheet(item: $renaming) { workspace in
                WorkspaceRenameSheet(store: store, workspace: workspace)
            }
            .alert("Remove workspace?", isPresented: removingBinding, presenting: removing) { workspace in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { await store.remove(workspace) }
                }
            } message: { workspace in
                Text("Remove \"\(workspace.name)\" from the workspace list?\n\n"
                   + "This only forgets the folder here — nothing on disk is deleted.")
            }
    }

    private var removingBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.workspaces.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage, store.workspaces.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .frame(maxHeight: .infinity)
        } else if store.isEmpty {
            ScrollView {
                WorkspacesEmptyState(
                    symbol: "folder.badge.plus",
                    title: "No workspaces yet",
                    hint: "Tap + to add a folder for the agent to work in.")
                    .padding(.top, 100)
            }
            .refreshable { await store.refresh() }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(store.workspaces) { workspace in
                WorkspaceRow(workspace: workspace, isLastUsed: store.isLastUsed(workspace),
                             onRename: { renaming = workspace },
                             onRemove: { removing = workspace })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
            .onMove { source, destination in
                Task { await store.move(fromOffsets: source, toOffset: destination) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }
}

/// One workspace: folder chip (tinted on the active one), name + "LAST USED"
/// badge, the absolute path, and an overflow menu.
struct WorkspaceRow: View {
    let workspace: Workspace
    let isLastUsed: Bool
    let onRename: () -> Void
    let onRemove: () -> Void

    private var accent: Color { isLastUsed ? JcTheme.success : JcTheme.muted }

    var body: some View {
        GlassCard(padding: 12, blur: false, fill: JcTheme.surface,
                  borderColor: isLastUsed ? JcTheme.success.opacity(0.35) : JcTheme.glassBorder) {
            HStack(spacing: 12) {
                Image(systemName: isLastUsed ? "folder.fill" : "folder")
                    .font(.system(size: 19))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(isLastUsed ? 0.16 : 0.10), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(workspace.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if isLastUsed {
                            StatusPill("LAST USED", color: JcTheme.success, dense: true)
                        }
                    }
                    Text(workspace.path)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Menu {
                    Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
        }
    }
}

/// "Add workspace": a path field that queries `/suggest` as you type, with the
/// candidates listed beneath it. Suggestions fail soft — a failed lookup simply
/// shows nothing.
struct WorkspaceAddSheet: View {
    let store: WorkspacesStore
    @State private var path = ""

    var body: some View {
        FormSheet(title: "Add workspace", saveLabel: "Add",
                  onSave: { await store.add(path: path) }) {
            VStack(alignment: .leading, spacing: 8) {
                FormTextField(label: "Folder path", text: $path,
                              hint: "/Users/you/code/project")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !store.suggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(store.suggestions.enumerated()), id: \.offset) { index, suggestion in
                            if index > 0 {
                                Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                            }
                            Button {
                                path = suggestion
                                store.clearSuggestions()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 13))
                                        .foregroundStyle(JcTheme.muted)
                                    Text(suggestion)
                                        .font(.system(size: 13))
                                        .foregroundStyle(JcTheme.text)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(JcTheme.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    .padding(.bottom, 12)
                }
            }
            // The store debounces, so this can fire on every keystroke.
            .onChange(of: path) { _, new in store.suggest(prefix: new) }
        }
        .onDisappear { store.clearSuggestions() }
    }
}

/// "Rename workspace": the immutable path for context, then the display name.
struct WorkspaceRenameSheet: View {
    let store: WorkspacesStore
    let workspace: Workspace
    @State private var name: String

    init(store: WorkspacesStore, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
    }

    var body: some View {
        FormSheet(title: "Rename workspace", saveLabel: "Rename",
                  onSave: { await store.rename(workspace, to: name) }) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(JcTheme.muted)
                Text(workspace.path)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(JcTheme.surfaceAlt,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .padding(.bottom, 16)

            FormTextField(label: "Display name", text: $name,
                          hint: "A friendly name for this folder")
        }
    }
}

/// A framed icon, a bold title and a muted hint — the polished empty state the
/// Flutter screen used.
struct WorkspacesEmptyState: View {
    let symbol: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 64, height: 64)
                .background(JcTheme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
