import SwiftUI

/// The chat input bar: pending-attachment chips, the shared "+" picker, the "/"
/// command sheet, the growing text field and the send button.
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
        enabled && !sending && (!jcTrim(draft).isEmpty || !session.attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning = warning ?? session.attachments.attachError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(warning).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(JcTheme.amber)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            }
            if !session.attachments.isEmpty {
                AttachmentStrip(attachments: session.attachments.items) { session.attachments.remove($0) }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            HStack(alignment: .bottom, spacing: 4) {
                AttachControl(sink: session.attachments, enabled: enabled, allowsVideo: false)
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
