import SwiftUI

/// One row of the transcript. A user turn is a right-aligned slate bubble; an
/// assistant turn uses the open layout of ``ChatAssistantTurnCard``.
///
/// The row owns the vertical rhythm too, because only it knows both neighbours:
/// consecutive turns from the same speaker sit 6 pt apart, a change of speaker
/// gets 26 pt of air — `Esp32ChatView`'s spacing, and Flutter's.
struct ChatMessageRow: View {
    let row: ChatRow
    /// The first row in the list gets no leading gap.
    var isFirst = false
    var onCopy: (() -> Void)?
    var onRetryOnServer: (() -> Void)?
    /// Sends a filled-in form on as the user's reply.
    var onFormSubmit: ((String) -> Void)?
    /// Background jobs this reply started, as the store sees them now.
    var jobs: [HarnessJob] = []
    var onStopJob: ((String) -> Void)?

    var body: some View {
        content.padding(.top, isFirst ? 0 : (row.continuesSpeaker ? 6 : 26))
    }

    @ViewBuilder private var content: some View {
        if row.message.isUser {
            ChatUserBubble(message: row.message, onCopy: onCopy)
        } else {
            ChatAssistantTurnCard(message: row.message, onCopy: onCopy,
                                  onRetryOnServer: onRetryOnServer,
                                  onFormSubmit: onFormSubmit,
                                  jobs: jobs, onStopJob: onStopJob)
        }
    }
}

/// The user's own turn: a restrained blue surface hugged to the right, with any
/// attachments shown underneath the text inside the same bubble.
struct ChatUserBubble: View {
    let message: ChatMessage
    var onCopy: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 6) {
                let text = message.plainText
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(message.attachments) { ChatSentAttachment(attachment: $0) }
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 13)
            .background(JcTheme.blue.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(JcTheme.blue.opacity(0.10), lineWidth: 0.5))
            .foregroundStyle(JcTheme.text)
            .contextMenu {
                if let onCopy, !message.plainText.isEmpty {
                    Button { onCopy() } label: { Label("Copy", jcIcon: "doc.on.doc") }
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

extension EnvironmentValues {
    /// The open chat, so a sent attachment can fetch its file back from the server.
    @Entry var chatSessionID: String?
}

/// An attachment on a sent message: its preview (a photo, a PDF's first page, a
/// text file's opening lines), or the file's glyph and name when nothing can
/// draw it. Just-sent attachments carry their bytes; after a reload the server
/// only remembers the name, so the file is fetched back by it. Tapping opens
/// the built-in viewer.
struct ChatSentAttachment: View {
    let attachment: MessageAttachment
    @Environment(\.chatSessionID) private var sessionID
    @State private var preview: UIImage?
    @State private var viewing: ViewedAttachment?
    @State private var opening = false

    private static let previews = NSCache<NSString, UIImage>()

    private var source: String? {
        sessionID.map { ChatFilePreview.source(sessionID: $0, name: attachment.name) }
    }

    var body: some View {
        Button(action: open) {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .overlay { if opening { ProgressView().tint(.white) } }
            } else {
                HStack(spacing: 8) {
                    JcIcon(PendingAttachment.looksLikeVideo(attachment.name) ? "film" : "doc", size: 16)
                    Text(attachment.name).font(.system(size: 13)).lineLimit(1)
                    if opening { ProgressView().controlSize(.small) }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name)
        .task(id: attachment.id) { await loadPreview() }
        .attachmentViewer($viewing)
    }

    private func loadPreview() async {
        if let data = attachment.thumbnail, let image = UIImage(data: data) {
            preview = image
            return
        }
        guard let source, !ChatFilePreview.skipsRemotePreview(attachment.name) else { return }
        if let hit = Self.previews.object(forKey: source as NSString) {
            preview = hit
            return
        }
        guard let bytes = await ChatImageCache.shared.bytes(source),
              let data = await ChatFilePreview.thumbnail(of: bytes, name: attachment.name),
              let image = UIImage(data: data) else { return }
        Self.previews.setObject(image, forKey: source as NSString)
        preview = image
    }

    private func open() {
        if let data = attachment.data {
            viewing = ViewedAttachment(name: attachment.name, data: data)
            return
        }
        guard let source, !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            if let data = await ChatImageCache.shared.bytes(source) {
                viewing = ViewedAttachment(name: attachment.name, data: data)
            }
        }
    }
}
