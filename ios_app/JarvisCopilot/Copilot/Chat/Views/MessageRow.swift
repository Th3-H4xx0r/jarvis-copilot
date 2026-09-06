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

    var body: some View {
        content.padding(.top, isFirst ? 0 : (row.continuesSpeaker ? 6 : 26))
    }

    @ViewBuilder private var content: some View {
        if row.message.isUser {
            ChatUserBubble(message: row.message, onCopy: onCopy)
        } else {
            ChatAssistantTurnCard(message: row.message, onCopy: onCopy,
                                  onRetryOnServer: onRetryOnServer)
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
                    Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// An attachment on a sent message: a real preview when the bytes are still in
/// memory (this session), otherwise a filename chip — after a history reload the
/// server only remembers the name. Tapping a preview opens ``ImageViewerPage``.
struct ChatSentAttachment: View {
    let attachment: MessageAttachment
    @State private var fullscreen = false

    private var preview: Image? {
        #if canImport(UIKit)
        guard let data = attachment.thumbnail, let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }

    var body: some View {
        if let preview {
            Button { fullscreen = true } label: {
                preview
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $fullscreen) {
                NavigationStack { ImageViewerPage(image: preview) }
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "paperclip").font(.system(size: 10))
                Text(attachment.name).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
