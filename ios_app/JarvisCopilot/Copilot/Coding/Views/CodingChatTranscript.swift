import SwiftUI

/// The session's conversation, rendered like the rest of the app's chat
/// (`Esp32ChatView`): slate user bubbles on the right, translucent assistant
/// cards on the left, compact tool rows inside them and quiet metadata beneath.
/// Port of the transcript half of `coding/coding_chat.dart`.
///
/// The view owns no transport: `CodingSessionStore` polls `/messages` and the
/// terminal PTY is the input channel.
struct CodingChatTranscript: View {
    let session: CodingSessionStore
    let live: Bool
    let onOpenPrompt: () async -> Void

    private var transcript: CodingTranscript { session.transcript }

    var body: some View {
        VStack(spacing: 0) {
            header
            if transcript.isWaiting && !session.promptOpen {
                needsInputBanner.padding(.horizontal, 16).padding(.bottom, 8)
            }
            body(for: transcript)
        }
        // Links here come out of a model transcript — see `CodingLinkPolicy`.
        .codingSafeLinks()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                Spacer()
                CodingStateChip(activityState: transcript.activityState, live: live,
                                onTap: transcript.isWaiting ? { Task { await onOpenPrompt() } } : nil)
            }
            if let ctx = transcript.context { CodingContextGauge(ctx: ctx) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var needsInputBanner: some View {
        Button { Task { await onOpenPrompt() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").font(.system(size: 14))
                Text("Claude is asking for input — tap to answer")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13))
            }
            .foregroundStyle(CodingUI.purple)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(CodingUI.purple.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CodingUI.purple.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Body

    @ViewBuilder
    private func body(for t: CodingTranscript) -> some View {
        if t.noTranscript {
            emptyState(symbol: "bubble.left",
                       text: "No transcript yet — send a message or use the terminal.")
        } else if t.loading && t.messages.isEmpty {
            ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if t.messages.isEmpty && session.pendingSends.isEmpty {
            emptyState(symbol: "text.bubble", text: "Nothing here yet — say something below.")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.messages) { m in
                        CodingMessageTile(message: m,
                                          // A tool on the LAST assistant message with
                                          // no result yet is still executing.
                                          toolsRunning: session.showThinking
                                              && m.i == transcript.messages.count - 1)
                            .id("msg-\(m.i)")
                    }
                    ForEach(session.pendingSends) { p in
                        CodingPendingBubble(send: p, working: session.showThinking)
                    }
                    if session.showThinking {
                        CodingThinkingBubble(statusLine: transcript.statusLine)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await session.fetch(full: true) }
            // Deviation: Flutter only auto-scrolled while the user was already at
            // the bottom (`_stickToBottom`). There is no iOS 17 API to read a
            // ScrollView's offset without fighting the programmatic scroll, so
            // every append scrolls. `appendTick` only bumps when content really
            // arrived, so this is not a per-poll yank.
            .onChange(of: session.appendTick) { _, _ in
                // A reload (opening the chat) JUMPS; an append animates.
                if session.appendWasReload {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
            .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    private func emptyState(symbol: String, text: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 38))
                    .foregroundStyle(JcTheme.muted.opacity(0.6))
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.top, 80)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await session.fetch(full: true) }
    }
}

// MARK: - State chip & gauge

/// The live chip: a spinner while working, a purple badge while waiting (tap to
/// re-open the prompt), otherwise Idle / Live / Offline.
struct CodingStateChip: View {
    let activityState: String?
    let live: Bool
    var onTap: (() -> Void)?

    var body: some View {
        let chip = CodingUI.stateChip(activityState: activityState, live: live)
        let content = HStack(spacing: 6) {
            if chip.spinning {
                ProgressView().controlSize(.mini).tint(chip.color)
                    .frame(width: 11, height: 11)
            } else {
                Circle().fill(chip.color).frame(width: 8, height: 8)
            }
            Text(chip.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(chip.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chip.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(chip.color.opacity(0.32), lineWidth: 1))

        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Slim per-chat context-window gauge: a thin fill bar + "NN% · used/window".
struct CodingContextGauge: View {
    let ctx: ChatContext

    var body: some View {
        HStack(spacing: 9) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(JcTheme.glassBorder)
                    Capsule().fill(CodingUI.contextColor(pct: ctx.pct))
                        .frame(width: max(1, geo.size.width * min(1, Double(max(0, ctx.pct)) / 100)))
                }
            }
            .frame(height: 5)
            Text("\(ctx.pct)% · \(ctx.usedLabel)/\(ctx.windowLabel)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(JcTheme.muted)
        }
    }
}

// MARK: - Message tile

/// One conversation message. A user turn is a slate bubble on the right; an
/// assistant turn is a translucent card with its tool rows and text.
struct CodingMessageTile: View {
    let message: CodingChatMessage
    var toolsRunning = false

    var body: some View {
        if message.isUser { userBubble } else { assistantBlock }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(JcTheme.slate,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                CodingTimestamp(ts: message.ts)
            }
        }
        .padding(.vertical, 5)
    }

    private var assistantBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(JcTheme.accent.opacity(0.18)).frame(width: 26, height: 26)
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(JcTheme.accent)
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if !message.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.tools) { tool in
                            CodingToolCard(tool: tool, running: toolsRunning && tool.running)
                        }
                    }
                }
                if !CodingUI.trim(message.text).isEmpty {
                    Text(CodingMarkdown.render(message.text))
                        .font(.system(size: 14.5))
                        .foregroundStyle(JcTheme.text)
                        .textSelection(.enabled)
                }
                CodingTimestamp(ts: message.ts)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 24)
        }
        .padding(.vertical, 5)
    }
}

/// The quiet time under a bubble — "14:03" today, "11/13 22:13" otherwise.
struct CodingTimestamp: View {
    let ts: Double?

    var body: some View {
        if let label = CodingUI.messageTime(ts, now: Date()) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(JcTheme.muted.opacity(0.65))
        }
    }
}

/// A user message delivered to the PTY but not yet echoed by the transcript —
/// "Queued" while Claude is mid-turn (the TUI processes it after the turn).
struct CodingPendingBubble: View {
    let send: PendingSend
    let working: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(send.text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(JcTheme.slate.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 3) {
                    Image(systemName: working ? "clock" : "checkmark")
                        .font(.system(size: 9))
                    Text(working ? "Queued" : "Sent").font(.system(size: 10.5))
                }
                .foregroundStyle(JcTheme.muted.opacity(0.7))
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Markdown

/// Inline markdown the way the rest of the app renders it (`Esp32ChatView`):
/// bold/italic/links/inline code kept, whitespace preserved, everything else
/// verbatim. Flutter used a full block renderer; SwiftUI's `AttributedString`
/// parser is inline-only, which keeps code fences readable as plain text rather
/// than mangling them.
enum CodingMarkdown {
    static func render(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var a = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 13, design: .monospaced)
        }
        return a
    }
}
