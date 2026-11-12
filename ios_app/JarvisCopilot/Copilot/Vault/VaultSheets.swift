import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add

/// The + sheet: what can go into this folder.
struct VaultAddSheet: View {
    enum Choice { case note, link, photos, camera, files, folder }

    let folderName: String
    let pick: (Choice) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add to \(folderName)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .padding(.top, 22)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                tile("note.text", "New note", .note)
                tile("link", "Paste link", .link)
                tile("photo.on.rectangle", "Photos", .photos)
                tile("camera", "Camera", .camera)
                tile("doc", "Files", .files)
                tile("folder.badge.plus", "New folder", .folder)
            }
            .padding(.horizontal, JcUnified.pageInset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(JcTheme.bg)
        .presentationBackground(JcTheme.bg)
    }

    private func tile(_ symbol: String, _ title: String, _ choice: Choice) -> some View {
        Button { pick(choice) } label: {
            VStack(spacing: 8) {
                JcIcon(symbol, size: 22)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(JcTheme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Link

/// Paste a link, see the preview the vault will keep (thumbnail, site, duration), then save.
struct VaultLinkSheet: View {
    @ObservedObject var session: VaultSession
    let folderID: String
    let folderName: String
    let done: (Bool) -> Void

    @State private var text = ""
    @State private var preview: VaultAPI.LinkPreview?
    @State private var previewImage: UIImage?
    @State private var fetching = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var url: String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host, host.contains(".") else { return nil }
        return u.absoluteString
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    JcSectionLabel("Link", first: true)
                    HStack(spacing: 8) {
                        TextField("https://", text: $text)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(JcTheme.text)
                            .textFieldStyle(.plain)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                        PasteButton(payloadType: URL.self) { urls in
                            if let first = urls.first { text = first.absoluteString }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.iconOnly)
                        .tint(JcButton.fill)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if fetching {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(JcTheme.muted)
                            Text("Getting the preview…").font(.system(size: 14)).foregroundStyle(JcTheme.muted)
                        }
                        .padding(.top, 16)
                    } else if let preview {
                        JcSectionLabel("Preview")
                        card(preview)
                    }
                    if let error {
                        Text(error).font(JcText.small).foregroundStyle(JcTheme.danger).padding(.top, 10)
                    }
                    GradientButton("Save to \(folderName)", busy: saving, full: true,
                                   action: url == nil || fetching ? nil : { Task { await save() } })
                        .padding(.top, 24)
                }
            }
            .jcPageChrome("Save a link", header: .inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { done(false) }.foregroundStyle(JcTheme.text)
                }
            }
        }
        .presentationBackground(JcTheme.bg)
        .onAppear { focused = true }
        .task(id: url) { await fetchPreview() }
        .vaultScreen(session)
    }

    private func card(_ p: VaultAPI.LinkPreview) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack {
                        JcTheme.surfaceAlt
                        if let previewImage {
                            Image(uiImage: previewImage).resizable().scaledToFill()
                        } else {
                            JcIcon("link", size: 28).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
                .overlay { if p.isVideo { VaultPlayBadge() } }
                .overlay(alignment: .bottomTrailing) {
                    if let d = VaultFormat.duration(p.duration) { VaultDurationChip(text: d) }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title.isEmpty ? p.domain : p.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                Text([p.siteName.isEmpty ? p.domain : p.siteName, p.author].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            .padding(12)
        }
        .background(JcTheme.glassFill, in: shape)
        .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
        .clipShape(shape)
    }

    private func fetchPreview() async {
        preview = nil
        previewImage = nil
        error = nil
        guard let url else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        fetching = true
        defer { fetching = false }
        do {
            let p = try await session.call { try await session.api.linkPreview(url, token: $0) }
            guard !Task.isCancelled else { return }
            preview = p
            previewImage = p.thumb.flatMap(UIImage.init(data:))
        } catch is CancellationError {
        } catch {
            // No preview is fine: the link still saves, and the server tries again later.
            self.error = nil
        }
    }

    private func save() async {
        guard let url else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await session.call { try await session.api.createLink(url: url, parent: folderID, token: $0) }
            done(true)
        } catch {
            self.error = apiErrorLine(error)
        }
    }
}

// MARK: - Photos

/// A photo or video picked from the library, copied into the app's temporary folder until it's up.
struct VaultPickedFile: Hashable {
    let url: URL
    let assetID: String?
    /// What the item is called in the vault ("IMG_4021.HEIC", "Photo 2026-11-12 09.41.jpg").
    let name: String
}

enum VaultTemp {
    private static var importDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-import", isDirectory: true)
    }

    /// Plaintext copies waiting to upload. Complete file protection: unreadable while the phone is locked.
    static func newURL(ext: String) -> URL {
        let dir = importDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// Decrypted copies handed to the share sheet: gone whenever the vault locks.
    static func clearShared() {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("vault-share-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private static var cleared = false

    /// At launch nothing is uploading yet: whatever a killed run left behind goes.
    @MainActor
    static func clearAtLaunch() {
        guard !cleared else { return }
        cleared = true
        clearShared()
        try? FileManager.default.removeItem(at: importDir)
    }

    static func cameraName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Camera \(f.string(from: Date())).\(ext)"
    }
}

/// The system photo picker over the whole library, so each pick carries its asset id (needed to
/// take the original out of Photos after import).
struct VaultPhotoPicker: UIViewControllerRepresentable {
    let done: ([VaultPickedFile]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: ([VaultPickedFile]) -> Void
        init(done: @escaping ([VaultPickedFile]) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { done([]); return }
            Task {
                var out: [VaultPickedFile] = []
                for result in results {
                    if let url = await Self.copy(result.itemProvider) {
                        let base = result.itemProvider.suggestedName ?? "Photo"
                        let name = (base as NSString).pathExtension.isEmpty ? base + "." + url.pathExtension : base
                        out.append(VaultPickedFile(url: url, assetID: result.assetIdentifier, name: name))
                    }
                }
                await MainActor.run { done(out) }
            }
        }

        private static func copy(_ provider: NSItemProvider) async -> URL? {
            let type: UTType? = [UTType.movie, .image].first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
            guard let type else { return nil }
            let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true }
                ?? type.identifier
            return await withCheckedContinuation { cont in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    guard let url else { cont.resume(returning: nil); return }
                    let ext = url.pathExtension.isEmpty ? (UTType(identifier)?.preferredFilenameExtension ?? "dat")
                                                        : url.pathExtension
                    let dest = VaultTemp.newURL(ext: ext)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        cont.resume(returning: dest)
                    } catch {
                        cont.resume(returning: nil)
                    }
                }
            }
        }
    }
}

/// The camera, for a photo or a video straight into the vault (never into Photos).
struct VaultCameraPicker: UIViewControllerRepresentable {
    let done: (VaultPickedFile?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (VaultPickedFile?) -> Void
        init(done: @escaping (VaultPickedFile?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                let ext = movie.pathExtension.isEmpty ? "mov" : movie.pathExtension
                let dest = VaultTemp.newURL(ext: ext)
                // Moved, not copied: UIKit's own capture file mustn't stay behind in tmp.
                if (try? FileManager.default.moveItem(at: movie, to: dest)) != nil {
                    done(VaultPickedFile(url: dest, assetID: nil, name: VaultTemp.cameraName(ext: ext))); return
                }
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                let dest = VaultTemp.newURL(ext: "jpg")
                if (try? data.write(to: dest, options: .completeFileProtection)) != nil {
                    done(VaultPickedFile(url: dest, assetID: nil, name: VaultTemp.cameraName(ext: "jpg"))); return
                }
            }
            done(nil)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// After picking from Photos: what's going in, and whether the originals leave the camera roll.
struct VaultPhotoImportSheet: View {
    let files: [VaultPickedFile]
    let folderName: String
    let confirm: (Bool) -> Void
    let onCancel: () -> Void

    @State private var removeOriginals = true
    @State private var thumbs: [URL: UIImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(files.prefix(9), id: \.self) { file in
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    ZStack {
                                        JcTheme.surfaceAlt
                                        if let img = thumbs[file.url] { Image(uiImage: img).resizable().scaledToFill() }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.top, 8)
                    if files.count > 9 {
                        Text("and \(files.count - 9) more")
                            .font(.system(size: 13)).foregroundStyle(JcTheme.muted).padding(.top, 6)
                    }
                    JcSectionLabel("After import")
                    JcCard(padding: 0) {
                        JcRow(symbol: "trash", title: "Remove from Photos after import",
                              subtitle: "iOS asks you to confirm before anything is removed", last: true) {
                            Toggle("", isOn: $removeOriginals).labelsHidden()
                        }
                        .disabled(files.allSatisfy { $0.assetID == nil })
                    }
                    GradientButton("Import to \(folderName)", full: true) { confirm(removeOriginals) }
                        .padding(.top, 24)
                }
            }
            .jcPageChrome(files.count == 1 ? "1 item selected" : "\(files.count) items selected", header: .inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundStyle(JcTheme.text)
                }
            }
        }
        .presentationBackground(JcTheme.bg)
        .interactiveDismissDisabled()
        .task {
            for file in files.prefix(9) {
                if let data = await VaultMediaInfo.thumbnail(file.url), let img = UIImage(data: data) {
                    thumbs[file.url] = img
                }
            }
        }
    }
}

// MARK: - Move

/// The folder tree, to pick where things go.
struct VaultMoveSheet: View {
    @ObservedObject var session: VaultSession
    /// Moving a folder: it and everything under it can't be the target.
    let excludingFolder: String?
    let current: String
    let pick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [VaultFolder] = []
    @State private var loaded = false

    private struct Row: Identifiable { let folder: VaultFolder; let depth: Int; var id: String { folder.id } }

    private var rows: [Row] {
        var out = [Row(folder: VaultFolder(id: VaultFolder.rootID, parentID: nil, name: "Vault", count: 0), depth: 0)]
        func walk(_ parent: String, _ depth: Int) {
            for f in folders.filter({ ($0.parentID ?? VaultFolder.rootID) == parent })
                .sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                if f.id == excludingFolder { continue }
                out.append(Row(folder: f, depth: depth))
                walk(f.id, depth + 1)
            }
        }
        walk(VaultFolder.rootID, 1)
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    JcCard(padding: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            JcRow(symbol: row.folder.id == VaultFolder.rootID ? "lock" : "folder",
                                  title: row.folder.name, last: i == rows.count - 1,
                                  action: row.folder.id == current ? nil : { pick(row.folder.id) }) {
                                if row.folder.id == current {
                                    Text("Here").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 18)
                            .opacity(row.folder.id == current ? 0.5 : 1)
                        }
                    }
                    .padding(.top, 8)
                    if !loaded { ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity).padding(.top, 20) }
                }
            }
            .jcPageChrome("Move to", header: .inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(JcTheme.text)
                }
            }
        }
        .presentationBackground(JcTheme.bg)
        .task {
            folders = (try? await session.call { try await session.api.tree(token: $0) }) ?? []
            loaded = true
        }
        .vaultScreen(session)
    }
}

// MARK: - Share out

/// Decrypted copies handed to the share sheet, cleaned up when it closes.
struct VaultShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    let temporaryFiles: [URL]

    @MainActor
    static func make(_ chosen: [VaultItem], session: VaultSession) async throws -> VaultShareRequest {
        var items: [Any] = []
        var temps: [URL] = []
        for item in chosen {
            switch item.kind {
            case .link:
                if let link = item.link, let url = URL(string: link.url) { items.append(url) }
            case .note:
                let full = try await session.call { try await session.api.item(item.id, token: $0) }
                let text = [full.title, full.body ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                items.append(text)
            default:
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-share-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                temps.append(dir)
                var name = item.filename.isEmpty ? item.displayTitle : item.filename
                if (name as NSString).pathExtension.isEmpty { name += "." + item.fileExtension }
                let url = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
                do {
                    try await session.call { try await session.api.download(item, to: url, token: $0) }
                } catch {
                    for t in temps { try? FileManager.default.removeItem(at: t) }
                    throw error
                }
                items.append(url)
            }
        }
        return VaultShareRequest(items: items, temporaryFiles: temps)
    }
}

struct VaultShareSheet: UIViewControllerRepresentable {
    let request: VaultShareRequest

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: request.items, applicationActivities: nil)
        let temps = request.temporaryFiles
        vc.completionWithItemsHandler = { _, _, _, _ in
            for url in temps { try? FileManager.default.removeItem(at: url) }
        }
        return vc
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
