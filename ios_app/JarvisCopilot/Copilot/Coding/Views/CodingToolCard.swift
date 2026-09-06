import SwiftUI

/// One tool use inside an assistant turn: a compact row (spinner while it runs,
/// icon + name + one-line summary when it's done) that expands to its output,
/// with a file-edit tool's unified diff always visible. Port of `_ToolCard`.
struct CodingToolCard: View {
    let tool: CodingChatTool
    /// The turn is still working AND this tool has no result — spin. A COMPLETED
    /// tool with empty output must never spin forever.
    var running = false

    @State private var expanded = false

    private var isSubagent: Bool { tool.isSubagent }
    private var hasOutput: Bool { !CodingUI.trim(tool.output).isEmpty }
    private var tint: Color {
        if isSubagent { return tool.ok ? CodingUI.purple : JcTheme.danger }
        return tool.ok ? JcTheme.cyan : JcTheme.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if !tool.diff.isEmpty { CodingDiffBlock(lines: tool.diff) }
            if expanded && hasOutput { output }
        }
        .background(isSubagent ? CodingUI.purple.opacity(0.07) : JcTheme.glassFill,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSubagent ? CodingUI.purple.opacity(0.30) : JcTheme.glassBorder,
                          lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var headerRow: some View {
        Button {
            if hasOutput { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
        } label: {
            HStack(spacing: 8) {
                if running || tool.running {
                    ProgressView().controlSize(.mini)
                        .tint(isSubagent ? CodingUI.purple : CodingUI.green)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint)
                        .frame(width: 16, height: 16)
                }
                Text(name)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSubagent ? CodingUI.purple : JcTheme.text)
                Text(tool.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hasOutput {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasOutput)
    }

    private var symbol: String {
        if isSubagent { return tool.ok ? "point.3.connected.trianglepath.dotted" : "exclamationmark.triangle" }
        return tool.ok ? "wrench.and.screwdriver" : "exclamationmark.triangle"
    }

    private var name: String {
        if isSubagent { return tool.subagentType.isEmpty ? "subagent" : tool.subagentType }
        return tool.name
    }

    private var output: some View {
        ScrollView(.horizontal) {
            Text(trimmedOutput)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CodingUI.paneMuted)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodingUI.pane)
    }

    private var trimmedOutput: String {
        var s = tool.output
        while let last = s.last, last == "\n" || last == " " { s.removeLast() }
        return s
    }
}

/// Red/green unified-diff lines for a file-edit tool. Always visible (not behind
/// the expander) — "edited a file" alone tells you nothing on a phone.
struct CodingDiffBlock: View {
    let lines: [String]

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodingUI.pane)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return CodingUI.diffAdd }
        if line.hasPrefix("-") { return CodingUI.diffDel }
        if line.hasPrefix("@@") { return JcTheme.muted }
        return CodingUI.paneMuted
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return CodingUI.diffAdd.opacity(0.13) }
        if line.hasPrefix("-") { return CodingUI.diffDel.opacity(0.13) }
        return .clear
    }
}

// MARK: - Thinking

/// The typing-style indicator shown while Claude works. When the server sends a
/// live status line ("✳ Zesting… (50s · ↑ 2.0k tokens)") its parts are styled
/// individually: verb salmon, elapsed muted, tokens blue, effort purple.
struct CodingThinkingBubble: View {
    let statusLine: String?

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                CodingThinkingDots()
                label
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(JcTheme.glassFill,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var label: some View {
        if let status = LiveStatus.parse(statusLine) {
            Text(styled(status))
                .lineLimit(2)
                .frame(maxWidth: 260, alignment: .leading)
        } else {
            Text("Working…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CodingUI.green.opacity(0.9))
        }
    }

    private func styled(_ s: LiveStatus) -> AttributedString {
        var out = segment(s.verb, size: 12, weight: .semibold, color: Color(jcHex: 0xFB7185))
        append(&out, s.elapsed, JcTheme.muted)
        append(&out, s.tokens, JcTheme.primaryBlueHi.opacity(0.9))
        append(&out, s.effort, CodingUI.purple.opacity(0.9))
        for extra in s.extra { append(&out, extra, JcTheme.muted) }
        return out
    }

    private func append(_ out: inout AttributedString, _ text: String?, _ color: Color) {
        guard let text, !text.isEmpty else { return }
        out += segment("  ·  ", size: 11.5, weight: .regular, color: JcTheme.muted)
        out += segment(text, size: 11.5, weight: .regular, color: color)
    }

    private func segment(_ text: String, size: CGFloat, weight: Font.Weight,
                         color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.font = .system(size: size, weight: weight, design: .monospaced)
        a.foregroundColor = color
        return a
    }
}

/// Three dots rising in sequence. Named for this area: `ThinkingDots` already
/// belongs to `Esp32ChatView`.
struct CodingThinkingDots: View {
    var size: CGFloat = 6
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(CodingUI.green.opacity(phase ? 1 : 0.35))
                    .frame(width: size, height: size)
                    .offset(y: phase ? -2.5 : 0)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.18), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
