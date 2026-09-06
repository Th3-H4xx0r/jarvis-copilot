import SwiftUI

/// What Claude is asking, as a sheet. Structured options become one button each
/// (which sends just the option's KEY — no newline); otherwise the raw pane tail
/// is shown monospace with Esc / Enter controls. A free-text reply is always
/// available (text + `\r`). Port of `_PromptSheet`.
///
/// Every action AWAITS delivery: the tapped control spins, the sheet closes only
/// once the keys actually reached the server, and a failed send keeps it open
/// with an inline error. (Fire-and-forget closed instantly and the unanswered
/// prompt re-popped — the glitch this guards against.)
struct CodingPromptSheet: View {
    let prompt: CodingPromptState
    let sendKey: (String) async -> Bool
    let sendText: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var pending: String?
    @State private var failed = false
    @State private var reply = ""

    private var hasOptions: Bool { !prompt.options.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(JcTheme.glassBorder).padding(.vertical, 14)
                if hasOptions {
                    VStack(spacing: 8) {
                        ForEach(prompt.options) { option in
                            CodingPromptOptionButton(
                                option: option,
                                pending: pending == option.key,
                                disabled: pending != nil && pending != option.key,
                                // Just the key — NO newline.
                                action: { deliver(option.key) { await sendKey(option.key) } })
                        }
                    }
                } else if let raw = prompt.raw, !CodingUI.trim(raw).isEmpty {
                    rawPane(raw)
                }
                controls.padding(.top, 12)
                if failed { failureNote.padding(.top, 10) }
                freeText.padding(.top, 14)
            }
            .padding(20)
        }
        .background(JcTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 18))
                .foregroundStyle(CodingUI.purple)
                .frame(width: 38, height: 38)
                .background(CodingUI.purple.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CodingUI.purple.opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text("CLAUDE NEEDS YOUR INPUT")
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(CodingUI.purple.opacity(0.9))
                Text(CodingUI.trim(prompt.question ?? "").isEmpty
                     ? "Choose how to continue"
                     : CodingUI.trim(prompt.question!))
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(JcTheme.text)
            }
            Spacer(minLength: 0)
        }
    }

    private func rawPane(_ raw: String) -> some View {
        ScrollView(.horizontal) {
            Text(raw)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CodingUI.paneText)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            GlassButton(title: pending == "esc" ? "Sending…" : "Esc",
                        symbol: "escape", ghost: true, full: true,
                        action: pending == nil ? { deliver("esc") { await sendKey("\u{1b}") } } : nil)
            if !hasOptions {
                GlassButton(title: pending == "enter" ? "Sending…" : "Enter",
                            symbol: "return", ghost: true, full: true,
                            action: pending == nil ? { deliver("enter") { await sendKey("\r") } } : nil)
            }
        }
    }

    private var failureNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13))
            Text("Couldn’t reach the session — it may have detached. "
                 + "Try again or use the Terminal view.")
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(JcTheme.danger.opacity(0.95))
    }

    private var freeText: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Or type a reply…", text: $reply, axis: .vertical)
                .lineLimit(1...4)
                .jcFieldStyle()
            Button {
                let text = CodingUI.trim(reply)
                guard !text.isEmpty else { return }
                deliver("text") { await sendText(text) }
            } label: {
                Group {
                    if pending == "text" {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(JcTheme.blueGradient, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(pending != nil)
        }
    }

    private func deliver(_ tag: String, _ send: @escaping () async -> Bool) {
        guard pending == nil else { return }
        pending = tag
        failed = false
        Task {
            let ok = await send()
            if ok {
                dismiss()
            } else {
                pending = nil
                failed = true
            }
        }
    }
}

/// One structured option: a key chip + its label, with a delivery spinner.
struct CodingPromptOptionButton: View {
    let option: CodingPromptOption
    var pending = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(option.key)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(JcTheme.primaryBlueHi)
                    .frame(width: 26, height: 26)
                    .background(JcTheme.primaryBlue.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(option.label.isEmpty ? "Option \(option.key)" : option.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if pending {
                    ProgressView().controlSize(.small).tint(JcTheme.primaryBlueHi)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(JcTheme.primaryBlue.opacity(pending ? 0.20 : 0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(JcTheme.primaryBlue.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending || disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// The slash-command sheet. The list is `CodingSessionStore.commands` — the same
/// set the Flutter sheet offered; a command is typed into the TUI like any other
/// message.
struct CodingCommandSheet: View {
    let onRun: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("COMMANDS")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(JcTheme.muted)
                .padding(.bottom, 10)
            ForEach(CodingSessionStore.commands, id: \.command) { entry in
                Button { onRun(entry.command) } label: {
                    HStack(spacing: 12) {
                        Text(entry.command)
                            .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(JcTheme.primaryBlueHi)
                        Text(entry.help)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
