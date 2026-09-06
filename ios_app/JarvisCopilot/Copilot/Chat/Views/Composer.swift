import SwiftUI

/// The composer: one rounded field on the same material as the reply cards, a
/// thin border, the attach button and a 30 pt round send button — no separate
/// bar, no blur. `Esp32ChatView`'s composer, plus the attachment strip and the
/// pick-error line from `pages/chat_page.dart`.
struct ChatComposer: View {
    let store: ChatStore
    @Binding var draft: String
    /// Bumped on every send: a multi-line `TextField` keeps stale text on screen
    /// when its binding is cleared while focused, so the field is recreated.
    let generation: Int
    @FocusState.Binding var focused: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var canSend: Bool {
        // A typed reply while the agent's clarify question is open answers it —
        // the turn is still streaming, so the normal "not while streaming" rule
        // would wrongly disable the button (see `ChatStore.send`).
        if store.pendingClarify != nil {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return store.canSend(draft: draft)
    }

    /// A clarify question turns the button back into Send even though the turn is
    /// technically still streaming — the answer is what unblocks it.
    private var canStop: Bool { store.streaming && store.pendingClarify == nil }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.pendingAttachments.isEmpty {
                ChatAttachmentStrip(store: store)
                    .padding(.leading, 8).padding(.trailing, 4).padding(.top, 6)
            }
            if let attachError = store.attachError {
                Text(attachError)
                    .font(.caption)
                    .foregroundStyle(JcTheme.danger)
                    .padding(.leading, 12).padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ChatAttachControl(store: store, enabled: !store.streaming)
                    .padding(.bottom, 3)
                TextField("Message", text: $draft, axis: .vertical)
                    .id(generation)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 8)
                Button {
                    if canStop { onStop() } else { onSend() }
                } label: {
                    Image(systemName: canStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(sendFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStop && !canSend)
                .animation(.smooth(duration: 0.2), value: store.streaming)
                .animation(.smooth(duration: 0.2), value: canSend)
                .padding(.bottom, 4)
                .accessibilityLabel(canStop ? "Stop" : "Send")
            }
            .padding(.leading, 4).padding(.trailing, 6)
        }
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.07), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    private var sendFill: Color {
        if canStop { return Color.white.opacity(0.14) }
        return canSend ? JcTheme.slate : Color.white.opacity(0.14)
    }
}

/// The horizontal strip of picked-but-unsent attachments above the field.
/// Collapses to nothing when there are none.
struct ChatAttachmentStrip: View {
    let store: ChatStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.pendingAttachments) { attachment in
                    ChatAttachmentChip(attachment: attachment) {
                        store.removeAttachment(attachment)
                    }
                }
            }
        }
        .frame(height: 38)
    }
}

/// One pending attachment: its own thumbnail for an image, the poster frame (with
/// a play badge) for a video, a type glyph for anything else — plus the name, the
/// size, and an × to drop it.
struct ChatAttachmentChip: View {
    let attachment: ChatPendingAttachment
    let onRemove: () -> Void

    private var thumbnail: Image? {
        #if canImport(UIKit)
        guard let data = attachment.thumbnail, let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }

    private var glyph: String {
        if attachment.isVideo { return "film" }
        if attachment.isImage { return "photo" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)
                Text(ChatUIFormat.fileSize(attachment.size))
                    .font(.system(size: 9))
                    .foregroundStyle(JcTheme.muted)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, thumbnail == nil ? 10 : 4)
        .padding(.trailing, 2)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }

    @ViewBuilder private var leading: some View {
        if let thumbnail {
            ZStack {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if attachment.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
            }
        } else {
            Image(systemName: glyph).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
        }
    }
}
