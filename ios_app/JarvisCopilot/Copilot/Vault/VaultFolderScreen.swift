import SwiftUI

/// Settings → Secure vault: the lock, then the vault's top folder.
struct VaultRootView: View {
    @ObservedObject private var session = VaultSession.shared

    var body: some View {
        VaultFolderScreen(folderID: VaultFolder.rootID, title: "Vault")
    }
}

/// One folder: its folders, then its items, as a grid or a list. The pill holds search,
/// grid/list, select, add and (at the top) lock.
struct VaultFolderScreen: View {
    let folderID: String
    let title: String

    @ObservedObject private var session = VaultSession.shared
    @ObservedObject private var uploads = VaultUploads.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCamera = false
    @AppStorage("vault.layout.list") private var listLayout = false

    @State private var listing: VaultAPI.Listing?
    @State private var loadError: String?
    @State private var searching = false
    @State private var query = ""
    @State private var results: (folders: [VaultFolder], items: [VaultItem])?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var sheet: Sheet?
    @State private var openedItem: VaultItem?
    @State private var toast: String?
    @State private var confirmDelete = false
    @State private var folderToDelete: VaultFolder?
    @State private var renaming: Rename?
    @State private var renameText = ""
    @State private var newFolderName = ""
    @State private var askNewFolder = false
    @State private var moving: MoveRequest?
    @State private var showFiles = false
    @State private var shareFiles: VaultShareRequest?
    @FocusState private var searchFocused: Bool

    enum Sheet: Identifiable {
        case add, link, photos, importPhotos([VaultPickedFile])
        var id: String {
            switch self {
            case .add: return "add"
            case .link: return "link"
            case .photos: return "photos"
            case .importPhotos: return "import"
            }
        }
    }

    struct Rename: Identifiable {
        let id: String
        let isFolder: Bool
        let current: String
    }

    struct MoveRequest: Identifiable {
        let id = UUID()
        let items: [String]
        let folder: VaultFolder?
    }

    private var isRoot: Bool { folderID == VaultFolder.rootID }
    private var folders: [VaultFolder] { results?.folders ?? listing?.folders ?? [] }
    private var items: [VaultItem] { results?.items ?? listing?.items ?? [] }
    private var pageTitle: String {
        guard session.isUnlocked else { return "Vault" }
        if !isRoot, let name = listing?.folder.name, !name.isEmpty { return name }
        return title
    }

    var body: some View {
        ScrollView {
            JcPageColumn { content }
                .padding(.bottom, selecting || uploads.summary != nil ? 70 : 0)
        }
        .refreshable { await load() }
        .scrollDismissesKeyboard(.interactively)
        .vaultChrome(pageTitle) { if session.isUnlocked { pill } }
        .overlay(alignment: .bottom) {
            if selecting { selectionBar } else { VaultUploadsBar(uploads: uploads) }
        }
        .animation(.easeOut(duration: 0.2), value: selecting)
        .animation(.easeOut(duration: 0.2), value: uploads.summary)
        .moreToast($toast)
        .task(id: session.revision) { if session.isUnlocked { await load() } }
        .onChange(of: session.isUnlocked) { _, open in
            if open {
                Task { await load() }
            } else {
                // Nothing decrypted stays on a locked screen.
                listing = nil
                results = nil
                selecting = false
                selection.removeAll()
            }
        }
        .onChange(of: query) { _, q in Task { await search(q) } }
        .navigationDestination(item: $openedItem) { item in VaultItemScreen(itemID: item.id, initial: item) }
        .sheet(item: $sheet) { sheetView($0) }
        .sheet(item: $moving) { req in
            VaultMoveSheet(session: session, excludingFolder: req.folder?.id,
                           current: req.folder?.parentID ?? folderID) { target in
                Task { await move(req, to: target) }
            }
        }
        .sheet(item: $shareFiles) { VaultShareSheet(request: $0) }
        .fullScreenCover(isPresented: $showCamera) {
            VaultCameraPicker { file in
                showCamera = false
                if let file { uploads.enqueue(file.url, filename: file.name, parent: folderID, ownsFile: true) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { uploads.enqueue(url, parent: folderID, ownsFile: false) }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteSelection() } }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(folderToDelete.map { "Delete “\($0.name)” and everything in it?" } ?? "",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) { Task { await deleteFolder() } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("New folder", isPresented: $askNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { Task { await rename() } }
        }
        .onAppear { uploads.onFinished = { VaultSession.shared.changed() } }
        .vaultScreen(session)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let path = listing?.path, path.count > 1 {
            Text(path.map(\.name).joined(separator: " › "))
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.bottom, 4)
        }
        if searching { searchField }
        if let loadError, listing == nil {
            JcEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't open the vault", subtitle: loadError)
                .padding(.top, 60)
        } else if listing == nil {
            ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            if !folders.isEmpty {
                JcSectionLabel("Folders", first: !searching)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(folders) { folder in folderTile(folder) }
                }
            }
            JcSectionLabel(itemsLabel, first: folders.isEmpty && !searching)
            if items.isEmpty {
                JcCard {
                    Text(results != nil ? "No matches." : "Nothing here yet. Tap + to add a note, link, photo or file.")
                        .font(.system(size: 14))
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 10)
                }
            } else if listLayout {
                JcCard(padding: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        itemButton(item) {
                            VaultListRow(item: item, session: session, selecting: selecting,
                                         selected: selection.contains(item.id), last: i == items.count - 1)
                        }
                    }
                }
            } else {
                grid
            }
        }
    }

    private var itemsLabel: String {
        if let results { return results.items.count == 1 ? "1 result across all folders" : "\(results.items.count) results across all folders" }
        return "Items"
    }

    /// Video links take a whole row; everything else sits two to a row.
    private var grid: some View {
        let rows = gridRows(items)
        return VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(rows[r]) { item in
                        itemButton(item) {
                            VaultGridCard(item: item, session: session, selecting: selecting,
                                          selected: selection.contains(item.id))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if rows[r].count == 1, !rows[r][0].isWide { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func gridRows(_ items: [VaultItem]) -> [[VaultItem]] {
        var rows: [[VaultItem]] = []
        var pending: VaultItem?
        for item in items {
            if item.isWide {
                rows.append([item])
            } else if let p = pending {
                rows.append([p, item]); pending = nil
            } else {
                pending = item
            }
        }
        if let pending { rows.append([pending]) }
        return rows
    }

    private func itemButton<Label: View>(_ item: VaultItem, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if selecting {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                openedItem = item
            }
        } label: { label() }
        .buttonStyle(.plain)
        .contextMenu {
            if !selecting {
                if item.kind != .link {
                    Button("Rename", jcIcon: "pencil") {
                        renameText = item.displayTitle
                        renaming = Rename(id: item.id, isFolder: false, current: item.displayTitle)
                    }
                }
                Button("Move", jcIcon: "folder") { moving = MoveRequest(items: [item.id], folder: nil) }
                Button("Share", jcIcon: "square.and.arrow.up") { Task { await share([item]) } }
                Button("Delete", jcIcon: "trash", role: .destructive) {
                    selection = [item.id]
                    confirmDelete = true
                }
            }
        }
    }

    private func folderTile(_ folder: VaultFolder) -> some View {
        NavigationLink {
            VaultFolderScreen(folderID: folder.id, title: folder.name)
        } label: {
            VaultFolderTile(folder: folder)
        }
        .buttonStyle(.plain)
        .disabled(selecting)
        .contextMenu {
            Button("Rename", jcIcon: "pencil") {
                renameText = folder.name
                renaming = Rename(id: folder.id, isFolder: true, current: folder.name)
            }
            Button("Move", jcIcon: "folder") { moving = MoveRequest(items: [], folder: folder) }
            Button("Delete", jcIcon: "trash", role: .destructive) { folderToDelete = folder }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            JcIcon("magnifyingglass", size: 15).foregroundStyle(JcTheme.muted)
            TextField("Search notes, links, files", text: $query)
                .font(.system(size: 16))
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    JcIcon("xmark.circle.fill", size: 15).foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 4)
    }

    // MARK: Pill

    @ViewBuilder
    private var pill: some View {
        JcPageButton("magnifyingglass", label: searching ? "Close search" : "Search") {
            searching.toggle()
            query = ""
            results = nil
            searchFocused = searching
        }
        JcPageButton(listLayout ? "square.grid.2x2" : "list.bullet",
                     label: listLayout ? "Show as grid" : "Show as list") { listLayout.toggle() }
        JcPageButton(selecting ? "checkmark.circle.fill" : "checkmark.circle",
                     label: selecting ? "Done selecting" : "Select") {
            selecting.toggle()
            selection.removeAll()
        }
        JcPageButton("plus", label: "Add") { sheet = .add }
        if isRoot {
            JcPageButton("lock", label: "Lock the vault") {
                session.lock()
                dismiss()
            }
        }
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        let chosen = items.filter { selection.contains($0.id) }
        return HStack(spacing: 0) {
            barButton("folder", "Move", enabled: !chosen.isEmpty) {
                moving = MoveRequest(items: chosen.map(\.id), folder: nil)
            }
            barButton("square.and.arrow.up", "Share", enabled: !chosen.isEmpty) { Task { await share(chosen) } }
            barButton("trash", "Delete", enabled: !chosen.isEmpty, danger: true) { confirmDelete = true }
            barButton("xmark", "Done", enabled: true) {
                selecting = false
                selection.removeAll()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func barButton(_ symbol: String, _ title: String, enabled: Bool, danger: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                JcIcon(symbol, size: 19)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(danger ? JcTheme.danger : JcTheme.text)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : JcButton.disabledOpacity)
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete this item?" : "Delete \(selection.count) items?"
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .add:
            VaultAddSheet(folderName: pageTitle) { choice in
                sheet = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))   // let the first sheet finish closing
                    switch choice {
                    case .note: await newNote()
                    case .link: sheet = .link
                    case .photos: sheet = .photos
                    case .camera: showCamera = true
                    case .files: showFiles = true
                    case .folder:
                        newFolderName = ""
                        askNewFolder = true
                    }
                }
            }
            .presentationDetents([.height(300)])
        case .link:
            VaultLinkSheet(session: session, folderID: folderID, folderName: pageTitle) { saved in
                sheet = nil
                if saved { toast = "Saved with preview"; session.changed() }
            }
        case .photos:
            VaultPhotoPicker { picked in
                sheet = nil
                guard !picked.isEmpty else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    sheet = .importPhotos(picked)
                }
            }
            .ignoresSafeArea()
        case .importPhotos(let picked):
            VaultPhotoImportSheet(files: picked, folderName: pageTitle) { removeOriginals in
                sheet = nil
                for file in picked {
                    uploads.enqueue(file.url, filename: file.name, parent: folderID, ownsFile: true,
                                    assetID: file.assetID, removeOriginal: removeOriginals)
                }
            } onCancel: {
                sheet = nil
                for file in picked { try? FileManager.default.removeItem(at: file.url) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            listing = try await session.call { try await session.api.folder(folderID, token: $0) }
            loadError = nil
            if !query.isEmpty { await search(query) }
        } catch VaultError.locked {
        } catch {
            loadError = apiErrorLine(error)
        }
    }

    private func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard trimmed == query.trimmingCharacters(in: .whitespaces) else { return }
        if let found = try? await session.call({ try await session.api.search(trimmed, token: $0) }),
           trimmed == query.trimmingCharacters(in: .whitespaces) {
            results = found
        }
    }

    private func newNote() async {
        do {
            let note = try await session.call {
                try await session.api.createNote(title: "", body: "", parent: folderID, token: $0)
            }
            session.changed()
            openedItem = note
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try await session.call { try await session.api.createFolder(name: name, parent: folderID, token: $0) }
            session.changed()
            await session.saveFolderNamesForShareSheet()
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func rename() async {
        guard let r = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != r.current else { return }
        do {
            if r.isFolder {
                try await session.call { try await session.api.updateFolder(r.id, name: name, token: $0) }
                await session.saveFolderNamesForShareSheet()
            } else {
                try await session.call { try await session.api.updateItem(r.id, fields: ["title": name], token: $0) }
            }
            session.changed()
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func move(_ req: MoveRequest, to target: String) async {
        moving = nil
        do {
            if let folder = req.folder {
                try await session.call { try await session.api.updateFolder(folder.id, parent: target, token: $0) }
                await session.saveFolderNamesForShareSheet()
                toast = "Moved"
            } else {
                try await session.call { try await session.api.move(req.items, to: target, token: $0) }
                toast = req.items.count == 1 ? "Moved" : "Moved \(req.items.count)"
            }
            selecting = false
            selection.removeAll()
            session.changed()
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func deleteSelection() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        do {
            try await session.call { try await session.api.delete(ids, token: $0) }
            toast = ids.count == 1 ? "Deleted" : "Deleted \(ids.count)"
            selecting = false
            selection.removeAll()
            session.changed()
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func deleteFolder() async {
        guard let folder = folderToDelete else { return }
        folderToDelete = nil
        do {
            try await session.call { try await session.api.deleteFolder(folder.id, token: $0) }
            toast = "Folder deleted"
            session.changed()
            await session.saveFolderNamesForShareSheet()
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func share(_ chosen: [VaultItem]) async {
        do {
            shareFiles = try await VaultShareRequest.make(chosen, session: session)
        } catch {
            toast = apiErrorLine(error)
        }
    }
}
