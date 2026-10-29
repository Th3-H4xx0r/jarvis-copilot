import SwiftUI

/// A glass composer with comfortable touch targets. Attachment previews and
/// errors grow above the field; the surrounding page reserves its layout space.
struct ChatComposer: View {
    let store: ChatStore
    /// What the empty field says. A screen that uses the chat for one job asks
    /// for that job rather than for anything at all.
    var placeholder: String = "Message Jarvis"
    @Binding var draft: String
    @Binding var focused: Bool
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 28, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.pendingAttachments.isEmpty {
                AttachmentStrip(attachments: store.pendingAttachments) { store.removeAttachment($0) }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            }
            if let attachError = store.attachError {
                Text(attachError)
                    .font(.caption)
                    .foregroundStyle(JcTheme.danger)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachControl(sink: store, enabled: !store.streaming)
                // Paste attaches a copied image or file, like "+" does — but not
                // mid-reply, where "+" is off too.
                ComposerTextView(text: $draft, focused: $focused,
                                 onPasteAttachments: store.streaming ? nil : { providers in
                                     Task { await PasteboardAttachments.add(providers, to: store) }
                                 })
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .foregroundStyle(JcTheme.muted)
                                .padding(.vertical, 11)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                Button {
                    if canStop { onStop() } else { onSend() }
                } label: {
                    JcIcon(canStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canStop ? JcTheme.text : (canSend ? JcTheme.accent : JcTheme.muted))
                        .frame(width: 44, height: 44)
                        .jcLiquidGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStop && !canSend)
                .animation(.smooth(duration: 0.2), value: store.streaming)
                .animation(.smooth(duration: 0.2), value: canSend)
                .accessibilityLabel(canStop ? "Stop" : "Send")
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
        .jcLiquidGlass(in: shape)
        // The beam rides the composer's edge only while Jarvis is working on a reply.
        .jcBorderBeam(shape, active: store.streaming)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
}

/// The horizontal strip of picked-but-unsent attachments above a composer field,
/// shared by the Chat and Coding composers.
struct AttachmentStrip: View {
    let attachments: [PendingAttachment]
    let onRemove: (PendingAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) { onRemove(attachment) }
                }
            }
        }
        .frame(height: AttachmentChip.side)
    }
}

/// One pending attachment as a square tile, the way Claude shows them: the
/// picture itself (a video's poster with a play badge), or for a plain file its
/// glyph and type — no name, no size — with an × in the corner to drop it.
struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    static let side: CGFloat = 64
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    private var thumbnail: Image? {
        guard let data = attachment.thumbnail, let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }

    var body: some View {
        tile
            .frame(width: Self.side, height: Self.side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    JcIcon("xmark", size: 9, weight: .bold)
                        .foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(.white, in: Circle())
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(attachment.name)
    }

    @ViewBuilder private var tile: some View {
        if let thumbnail {
            ZStack {
                thumbnail.resizable().scaledToFill()
                if attachment.isVideo {
                    JcIcon("play.fill", size: 10)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
            }
        } else {
            VStack(spacing: 4) {
                JcIcon(attachment.isVideo ? "film" : "doc", size: 20)
                    .foregroundStyle(JcTheme.muted)
                let ext = (attachment.name as NSString).pathExtension.uppercased()
                if !ext.isEmpty {
                    Text(ext)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JcTheme.glassFill)
        }
    }
}
