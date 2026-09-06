import SwiftUI

/// One assistant turn with a quiet speaker label and room for the reply.
/// Reasoning, tools, errors, on-device retry and stats retain their own hierarchy.
struct ChatAssistantTurnCard: View {
    let message: ChatMessage
    var onCopy: (() -> Void)?
    var onRetryOnServer: (() -> Void)?

    @State private var copied = false
    @State private var selecting = false

    private var tools: [ToolInvocation] { message.tools }
    private var hasText: Bool { !message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: message.onDevice ? "bolt.fill" : "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.cyan)
                    .accessibilityHidden(true)
                Text("Jarvis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(JcTheme.text.opacity(0.8))
            }
            card

            if hasText, !message.streaming, !message.isError {
                actions
            }

            if !footer.isEmpty {
                ChatStatsLine(text: footer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatReasoningCard(text: message.reasoning, active: message.streaming && !hasText)
            }

            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tools) { ChatToolRow(tool: $0) }
                }
                .padding(12)
                .background(.white.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            }

            ForEach(message.blocks) { block in
                if let text = block.asText, !text.isEmpty {
                    if message.isError {
                        errorText(text.text)
                    } else {
                        ChatMarkdownText(text: text.text)
                    }
                }
            }

            if message.streaming && !hasText
                && message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !tools.contains(where: { !$0.done }) {
                ChatThinkingDots().padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { menu }
    }

    /// Small icon actions under a settled reply: copy the whole message, or open
    /// it in a selectable text view (SwiftUI's `textSelection` only copies a whole
    /// block, so partial selection needs a real `UITextView`).
    private var actions: some View {
        HStack(spacing: 14) {
            Button {
                if let onCopy { onCopy() } else {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = message.plainText
                    #endif
                }
                withAnimation(.snappy) { copied = true }
                Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(copied ? JcTheme.success : JcTheme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy message")

            Button { selecting = true } label: {
                Image(systemName: "text.cursor")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select text")
        }
        .padding(.top, -4)
        .sheet(isPresented: $selecting) {
            ChatSelectTextSheet(text: message.plainText)
        }
    }

    @ViewBuilder private var menu: some View {
        if hasText, let onCopy {
            Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if message.onDevice, !message.streaming, let onRetryOnServer {
            Button { onRetryOnServer() } label: {
                Label("Try on server", systemImage: "cloud.and.arrow.up")
            }
        }
    }

    private func errorText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(JcTheme.danger).frame(width: 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.danger)
                .padding(11)
        }
        .background(JcTheme.danger.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Stats only once the turn has settled — a half-counted line flickering
    /// under a streaming reply is noise. The on-device badge rides along here,
    /// as it does in Flutter.
    private var footer: String {
        guard !message.streaming else { return "" }
        let stats = message.stats?.line ?? ""
        if message.onDevice { return stats.isEmpty ? "On-device" : "On-device · \(stats)" }
        return stats
    }
}

/// A reply opened for partial selection: a plain `UITextView` (selectable, not
/// editable) so the usual iOS handles, "Copy" and "Select All" all work.
struct ChatSelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(edges: .bottom)
                .background(JcTheme.bg)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = text
                            #endif
                        } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy all")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

#if canImport(UIKit)
struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textColor = UIColor(JcTheme.text)
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        view.dataDetectorTypes = [.link]
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#else
struct SelectableTextView: View {
    let text: String
    var body: some View { ScrollView { Text(text).textSelection(.enabled).padding() } }
}
#endif
