import SwiftUI

/// One assistant turn: a 26 pt avatar beside a single translucent card holding —
/// in this order — the reasoning trace, the compact tool rows, and the reply
/// text; with the stats line tucked underneath in grey.
///
/// This is `Esp32ChatView`'s reply layout with the extra structure the Jarvis
/// chat has (`chat/widgets/message_view.dart`): interleaved blocks, an error
/// turn, the on-device badge and its "Try on server" retry.
struct ChatAssistantTurnCard: View {
    let message: ChatMessage
    var onCopy: (() -> Void)?
    var onRetryOnServer: (() -> Void)?

    private var tools: [ToolInvocation] { message.tools }
    private var hasText: Bool { !message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "Running <tool>…" while a call is in flight, "Thinking…" while the model
    /// reasons, nothing when we simply have not heard back yet.
    private var activityLabel: String? {
        if let last = tools.last, !last.done { return "Running \(last.shortName)…" }
        if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Thinking…" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                avatar.padding(.top, 2)
                card
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)

            if !footer.isEmpty {
                ChatStatsLine(text: footer)
                    .padding(.leading, 52)
                    .padding(.top, 4)
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(JcTheme.accent.opacity(0.18)).frame(width: 26, height: 26)
            Image(systemName: message.onDevice ? "bolt.fill" : "sparkles")
                .font(.caption)
                .foregroundStyle(message.onDevice ? JcTheme.cyan : JcTheme.accent)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatReasoningCard(text: message.reasoning, active: message.streaming && !hasText)
            }

            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { ChatToolRow(tool: $0) }
                }
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

            if message.streaming && !hasText {
                HStack(spacing: 8) {
                    ChatThinkingDots()
                    if let activityLabel {
                        Text(activityLabel).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { menu }
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
