import AVKit
import UniformTypeIdentifiers
import PDFKit
import SwiftUI

/// One item, opened: a link's big preview, a note's editor, a photo, a streaming video, a PDF,
/// or a file to hand to another app.
struct VaultItemScreen: View {
    let itemID: String
    let initial: VaultItem

    @ObservedObject private var session = VaultSession.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var savedSomething = false
    @Environment(\.openURL) private var openURL
    @State private var item: VaultItem?
    @State private var data: Data?
    @State private var loadError: String?
    @State private var toast: String?
    @State private var moving = false
    @State private var confirmDelete = false
    @State private var share: VaultShareRequest?
    @State private var sharing = false
    // Notes
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var savedTitle = ""
    @State private var savedBody = ""
    @State private var linkNote = ""
    @State private var savedLinkNote = ""
    @State private var askOpen = false
    @State private var browsing: VaultBrowserTarget?
    @State private var player: AVPlayer?
    @State private var playerLoader: VaultPlayerLoader?

    private var current: VaultItem { item ?? initial }

    var body: some View {
        ScrollView {
            JcPageColumn { content }
        }
        .scrollDismissesKeyboard(.interactively)
        .vaultChrome(current.kind == .note || !session.isUnlocked ? "" : current.displayTitle, header: .inline) {
            if session.isUnlocked {
                JcPageButton("square.and.arrow.up", label: "Share") { Task { await shareOut() } }
                    .disabled(sharing)
                JcPageButton("folder", label: "Move") { moving = true }
                JcPageButton("trash", label: "Delete", tint: JcTheme.danger) { confirmDelete = true }
            }
        }
        .moreToast($toast)
        .sheet(isPresented: $moving) {
            VaultMoveSheet(session: session, excludingFolder: nil, current: current.parentID) { target in
                Task { await move(to: target) }
            }
        }
        .sheet(item: $share) { VaultShareSheet(request: $0) }
        .confirmationDialog(current.link?.domain ?? "Open link", isPresented: $askOpen, titleVisibility: .visible) {
            Button("Private browser") { openLink(privately: true) }
            Button("Default browser") { openLink(privately: false) }
        } message: {
            Text("The private browser blocks ads, trackers and pop-ups, and keeps nothing after you close it.")
        }
        .fullScreenCover(item: $browsing) { VaultBrowserView(url: $0.url) }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This can't be undone.")
        }
        .task(id: session.isUnlocked) { if session.isUnlocked { await load() } }
        .onChange(of: session.isUnlocked) { _, open in
            guard !open else { return }
            // Decrypted bytes and the player (its token is dead now) go; unsaved typing stays.
            data = nil
            stopVideo()
        }
        .onChange(of: scenePhase) { _, phase in
            // Before the background lock: what he typed goes up with the live token.
            if phase == .inactive { Task { await saveNote() } }
        }
        .onDisappear {
            stopVideo()
            Task {
                await saveNote()
                if savedSomething { session.changed() }
            }
        }
        .vaultScreen(session)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch current.kind {
        case .link: linkView
        case .note: noteView
        case .image: imageView
        case .video: videoView
        case .pdf: pdfView
        case .file: fileView
        }
        if let loadError {
            Text(loadError).font(JcText.small).foregroundStyle(JcTheme.danger).padding(.top, 12)
        }
    }

    private var heroShape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    private var linkView: some View {
        let link = current.link
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { VaultThumb(item: current, session: session) }
                .overlay { if link?.isVideo == true { VaultPlayBadge(size: 64) } }
                .overlay(alignment: .bottomTrailing) {
                    if let d = VaultFormat.duration(current.duration) { VaultDurationChip(text: d) }
                }
                .clipShape(heroShape)
                .onTapGesture { askOpen = true }
                .padding(.top, 8)
            Text(current.displayTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .padding(.top, 14)
            HStack(spacing: 6) {
                VaultFavicon(item: current, session: session)
                Text(current.metaLine).lineLimit(1)
            }
            .font(.system(size: 14))
            .foregroundStyle(JcTheme.muted)
            .padding(.top, 6)
            HStack(spacing: 10) {
                GradientButton(link?.isVideo == true ? "Open video" : "Open page",
                               symbol: "arrow.up.right.square", full: true) { askOpen = true }
                Button {
                    // This iPhone only, and not for long: never onto his other devices' clipboards.
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: link?.url ?? ""]],
                                                  options: [.localOnly: true,
                                                            .expirationDate: Date().addingTimeInterval(120)])
                    toast = "Link copied"
                } label: {
                    JcIcon("doc.on.doc", size: 17)
                }
                .buttonStyle(.jcGlass(tint: JcTheme.text))
                .accessibilityLabel("Copy link")
            }
            .padding(.top, 16)
            if let d = link?.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 14)
            }
            JcSectionLabel("Your note")
            JcCard {
                TextField("Add a note", text: $linkNote, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.text)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .onSubmit { Task { await saveNote() } }
            }
            details([("Saved", VaultFormat.day(current.created)), ("Link", link?.domain ?? "")])
        }
    }

    private var noteView: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $noteTitle, axis: .vertical)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .padding(.top, 8)
            Text("Edited \(VaultFormat.day(current.updated)) · saved encrypted")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 4)
                .padding(.bottom, 14)
            JcCard {
                TextField("Write something", text: $noteBody, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(JcTheme.text)
                    .textFieldStyle(.plain)
                    .lineLimit(12...)
            }
        }
        .task(id: noteTitle + "\u{0}" + noteBody) {
            // Saves a moment after he stops typing.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await saveNote()
        }
    }

    @ViewBuilder
    private var imageView: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(heroShape)
                    .modifier(VaultZoom())
            } else {
                VaultThumb(item: current, session: session)
                    .aspectRatio(current.thumbAspect ?? 1, contentMode: .fit)
                    .clipShape(heroShape)
                    .overlay { if data == nil, loadError == nil { JcLoader().foregroundStyle(.white) } }
            }
        }
        .padding(.top, 8)
        details([("Size", VaultFormat.bytes(current.size)), ("Added", VaultFormat.day(current.created))])
    }

    @ViewBuilder
    private var videoView: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(current.thumbAspect ?? 16 / 9, contentMode: .fit)
                    .clipShape(heroShape)
            } else {
                Color.clear
                    .aspectRatio(current.thumbAspect ?? 16 / 9, contentMode: .fit)
                    .overlay { VaultThumb(item: current, session: session) }
                    .overlay { VaultPlayBadge(size: 64) }
                    .clipShape(heroShape)
                    .onTapGesture { startVideo() }
            }
        }
        .padding(.top, 8)
        details([("Length", VaultFormat.duration(current.duration) ?? "—"), ("Size", VaultFormat.bytes(current.size)),
                 ("Added", VaultFormat.day(current.created))])
    }

    @ViewBuilder
    private var pdfView: some View {
        Group {
            if let data {
                VaultPDFView(data: data)
                    .frame(height: 560)
                    .clipShape(heroShape)
            } else {
                VaultThumb(item: current, session: session)
                    .aspectRatio(8.5 / 11, contentMode: .fit)
                    .clipShape(heroShape)
                    .overlay { if loadError == nil { JcLoader().foregroundStyle(JcTheme.muted) } }
            }
        }
        .padding(.top, 8)
        details([("Pages", current.pages.map(String.init) ?? "—"), ("Size", VaultFormat.bytes(current.size)),
                 ("Added", VaultFormat.day(current.created))])
    }

    private var fileView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VaultThumb(item: current, session: session)
                .aspectRatio(1.4, contentMode: .fit)
                .clipShape(heroShape)
                .padding(.top, 8)
            GradientButton("Open in…", symbol: "square.and.arrow.up", busy: sharing, full: true) {
                Task { await shareOut() }
            }
            .padding(.top, 16)
            details([("Name", current.filename), ("Size", VaultFormat.bytes(current.size)),
                     ("Added", VaultFormat.day(current.created))])
        }
    }

    private func details(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Details")
            JcCard(padding: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    JcRow(title: rows[i].0, value: rows[i].1)
                }
                JcRow(title: "Encryption", value: "AES-256-GCM", last: true)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let fresh = try await session.call { try await session.api.item(itemID, token: $0) }
            item = fresh
            // Unsaved typing (from before a lock) wins over the server copy, then goes up.
            if fresh.kind == .note {
                let title = fresh.rawTitle ?? fresh.title
                if noteTitle == savedTitle { noteTitle = title }
                savedTitle = title
                if noteBody == savedBody { noteBody = fresh.body ?? "" }
                savedBody = fresh.body ?? ""
            }
            if fresh.kind == .link {
                if linkNote == savedLinkNote { linkNote = fresh.note }
                savedLinkNote = fresh.note
            }
            await saveNote()
            if [.image, .pdf].contains(fresh.kind), data == nil {
                data = try await session.call { try await session.api.content(itemID, token: $0) }
            }
        } catch VaultError.locked {
        } catch {
            loadError = apiErrorLine(error)
        }
    }

    private func saveNote() async {
        guard session.isUnlocked else { return }
        var fields: [String: Any] = [:]
        if current.kind == .note {
            if noteTitle != savedTitle { fields["title"] = noteTitle }
            if noteBody != savedBody { fields["body"] = noteBody }
        } else if current.kind == .link, linkNote != savedLinkNote {
            fields["note"] = linkNote
        }
        guard !fields.isEmpty else { return }
        let (t, b, n) = (noteTitle, noteBody, linkNote)
        do {
            try await session.call { try await session.api.updateItem(itemID, fields: fields, token: $0) }
            savedTitle = t; savedBody = b; savedLinkNote = n
            savedSomething = true
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func openLink(privately: Bool) {
        guard let s = current.link?.url, let url = URL(string: s) else { return }
        if privately { browsing = VaultBrowserTarget(url: url) } else { openURL(url) }
    }

    private func stopVideo() {
        player?.pause()
        player = nil
        playerLoader?.cancelAll()
        playerLoader = nil
    }

    private func startVideo() {
        guard let token = session.token else { return }
        let loader = VaultPlayerLoader(item: current, token: token, api: session.api) {
            Task { @MainActor in VaultSession.shared.touch() }
        }
        playerLoader = loader
        let p = AVPlayer(playerItem: loader.playerItem())
        player = p
        p.play()
    }

    private func shareOut() async {
        sharing = true
        defer { sharing = false }
        do {
            share = try await VaultShareRequest.make([current], session: session)
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func move(to target: String) async {
        moving = false
        do {
            try await session.call { try await session.api.move([itemID], to: target, token: $0) }
            session.changed()
            toast = "Moved"
            item = try? await session.call { try await session.api.item(itemID, token: $0) }
        } catch {
            toast = apiErrorLine(error)
        }
    }

    private func delete() async {
        do {
            try await session.call { try await session.api.delete([itemID], token: $0) }
            session.changed()
            dismiss()
        } catch {
            toast = apiErrorLine(error)
        }
    }
}

/// A link's site icon, small, before the site name.
struct VaultFavicon: View {
    let item: VaultItem
    @ObservedObject var session: VaultSession
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                JcIcon("globe", size: 12)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: "\(item.id)-\(item.link?.hasFavicon ?? false)") { image = await session.favicon(for: item) }
    }
}

/// Pinch to zoom a photo, double-tap to reset.
private struct VaultZoom: ViewModifier {
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale * pinch)
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(5, max(1, scale * value.magnification)) })
            .onTapGesture(count: 2) { withAnimation(.spring) { scale = 1 } }
            .zIndex(scale * pinch > 1 ? 1 : 0)
    }
}

/// PDFKit over the decrypted bytes in memory.
struct VaultPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .black
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
