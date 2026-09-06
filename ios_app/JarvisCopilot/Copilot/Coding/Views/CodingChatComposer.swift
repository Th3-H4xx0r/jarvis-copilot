import PhotosUI
import SwiftUI

/// The chat input bar: pending-attachment chips, the "+" picker, the "/" command
/// sheet, the growing text field and the send button. Port of `_ChatInputBar` +
/// `coding/coding_attach.dart`.
///
/// Every send goes through the terminal PTY (`CodingSessionStore.sendComposer`)
/// — attachments are uploaded first and folded in as `@path` references.
struct CodingChatComposer: View {
    let session: CodingSessionStore
    var enabled = true

    @State private var draft = ""
    /// Bumped on every send: a multi-line TextField keeps stale text on screen
    /// when its binding is cleared while focused, so the field is recreated.
    @State private var generation = 0
    @State private var sending = false
    @State private var commandsOpen = false
    @State private var warning: String?
    @FocusState private var focused: Bool

    private var hint: String {
        if !enabled { return "Session isn’t live" }
        // Sends still work mid-turn — the TUI queues/steers them.
        return session.showThinking ? "Steer Claude — queues mid-turn…" : "Message Claude…"
    }

    private var canSend: Bool {
        enabled && !sending && (!CodingUI.trim(draft).isEmpty || !session.attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(warning).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(JcTheme.amber)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            }
            CodingAttachmentChips(attachments: session.attachments)
            HStack(alignment: .bottom, spacing: 4) {
                CodingAttachControl(attachments: session.attachments, enabled: enabled)
                Button { commandsOpen = true } label: {
                    Text("/")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(enabled ? JcTheme.primaryBlueHi : JcTheme.muted.opacity(0.5))
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel("Commands")

                TextField(hint, text: $draft, axis: .vertical)
                    .id(generation)
                    .lineLimit(1...5)
                    .focused($focused)
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.text)
                    .padding(.vertical, 8)
                    .disabled(!enabled)

                Button(action: send) {
                    Group {
                        if sending {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        }
                    }
                    .foregroundStyle(canSend ? .white : JcTheme.muted)
                    .frame(width: 40, height: 40)
                    .background(canSend ? AnyShapeStyle(JcTheme.blueGradient)
                                        : AnyShapeStyle(JcTheme.glassFill), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.2), value: canSend)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(JcTheme.glassFill,
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sheet(isPresented: $commandsOpen) {
            CodingCommandSheet { command in
                commandsOpen = false
                Task {
                    // A slash command is a send like any other — dropping its
                    // result made `/compact` look like it had run when it hadn't.
                    warning = await session.sendText(command)
                        ? nil
                        : "Couldn’t send \(command) — check the Terminal view."
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        generation += 1
        sending = true
        warning = nil
        Task {
            let result = await session.sendComposer(text)
            sending = false
            if !result.sent {
                warning = "Couldn’t reach the session — check the Terminal view."
                // Give the text back rather than losing what was typed.
                draft = text
            } else if result.failed > 0 {
                warning = result.failed == 1
                    ? "An attachment couldn’t be uploaded — sent without it."
                    : "\(result.failed) attachments couldn’t be uploaded — sent without them."
            }
        }
    }
}

// MARK: - Attachments

/// The composer's "+": photo library and files, straight into
/// `CodingAttachments.add`. Picking is a view concern on iOS (the store never
/// touches PhotosUI), which is why the loading lives here.
struct CodingAttachControl: View {
    let attachments: CodingAttachments
    var enabled = true

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("File", systemImage: "doc") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel("Attach photo or file")
        .photosPicker(isPresented: $showPhotos, selection: $picked,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await load(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await load(files: urls) }
        }
    }

    @MainActor private func load(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                attachments.error = "Could not read that item."
                continue
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            attachments.add(name: "photo-\(Int(Date().timeIntervalSince1970))-\(offset).\(ext)",
                            data: data, isImage: true)
        }
    }

    @MainActor private func load(files urls: [URL]) async {
        for url in urls {
            // A picked document lives outside the sandbox until it's opened.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                attachments.error = "Could not read \(url.lastPathComponent)."
                continue
            }
            attachments.add(name: url.lastPathComponent, data: data)
        }
    }
}

/// The horizontal strip of picked-but-unsent chips above the composer.
struct CodingAttachmentChips: View {
    let attachments: CodingAttachments

    var body: some View {
        if !attachments.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments.items) { item in
                        chip(item)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 38)
            .padding(.bottom, 6)
        }
    }

    private func chip(_ item: PendingAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.isImage ? "photo" : "doc")
                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            Text(item.name)
                .font(.system(size: 12)).foregroundStyle(JcTheme.text)
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
            Button { attachments.remove(item) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}
