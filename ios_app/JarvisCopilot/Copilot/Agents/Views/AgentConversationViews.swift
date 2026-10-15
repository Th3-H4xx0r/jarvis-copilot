import SwiftUI

// The pieces of a session's conversation, the Claude-app way: your prompts in
// rounded bubbles on the right, the agent's words as plain Markdown, every
// tool call one quiet line that opens to its output, and each changed file a
// card that opens to its diff.

/// One conversation item.
/// Loads one message in full when you open a tool's output or a file's diff
/// (the chat list comes without them, to load fast).
struct AgentLoadDetails {
    let run: (Int) -> Void
    func callAsFunction(_ i: Int) { run(i) }
}

extension EnvironmentValues {
    @Entry var agentLoadDetails = AgentLoadDetails(run: { _ in })
}

/// While a row's details are on their way.
private struct AgentDetailsLoading: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Loading…").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
        }
        .padding(.vertical, 6)
    }
}

struct AgentConversationRow: View {
    let item: AgentConversationItem
    var cwd = ""
    var openDiff: (AgentFileEdit) -> Void = { _ in }

    var body: some View {
        switch item {
        case .prompt(_, let text):
            AgentPromptBubble(text: text)
                .padding(.top, 14)
                .padding(.bottom, 6)
        case .text(_, let text):
            ChatMarkdownText(text: text)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        case .tool(_, let tool):
            AgentToolRow(item: tool)
        case .tools(_, let summary, let tools):
            AgentToolGroupRow(summary: summary, items: tools)
        case .edit(_, let edit):
            AgentEditCard(edit: edit, cwd: cwd, openDiff: openDiff)
                .padding(.vertical, 5)
        }
    }
}

// MARK: - Prompts

/// What you asked: a rounded bubble on the right, like the Chat tab's.
struct AgentPromptBubble: View {
    let text: String
    var pending = false

    @State private var expanded = false
    private var long: Bool { text.count > 700 || text.filter(\.isNewline).count > 14 }

    var body: some View {
        HStack {
            Spacer(minLength: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(JcTheme.text.opacity(pending ? 0.7 : 1))
                    .lineLimit(long && !expanded ? 14 : nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(expanded ? "Show less" : "Show more") {
                        withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(JcTheme.blue.opacity(pending ? 0.08 : 0.13),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(JcTheme.blue.opacity(0.10), lineWidth: 0.5))
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", jcIcon: "doc.on.doc") }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// An instruction this phone sent: the bubble at once, then what became of it.
struct AgentOutgoingBubble: View {
    let outgoing: AgentOutgoing
    let retry: () -> Void
    let dismiss: () -> Void
    let openSettings: () -> Void

    private var failure: AgentSendFailure? {
        if case .failed(let f) = outgoing.phase { return f }
        return nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            AgentPromptBubble(text: outgoing.text, pending: outgoing.phase == .sending)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch outgoing.phase {
                case .sending:
                    AgentSpinner(size: 10, color: JcTheme.muted)
                case .sent:
                    JcIcon("checkmark", size: 10, weight: .semibold)
                case .failed:
                    JcIcon("exclamationmark.circle.fill", size: 11)
                }
                Text(outgoing.caption)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(failure == nil ? JcTheme.muted : JcTheme.danger)
            .frame(maxWidth: 300, alignment: .trailing)
            .padding(.horizontal, 22)
            if let failure {
                HStack(spacing: 8) {
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                    if failure.opensSettings {
                        Button("Code Master settings", action: openSettings)
                            .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    } else {
                        Button("Try again", action: retry)
                            .buttonStyle(.jcGlass(tint: JcTheme.text, compact: true))
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Tool rows

/// "Ran npm test": the tool's icon, its sentence, and a chevron that opens
/// its output in monospace.
struct AgentToolRow: View {
    let item: AgentToolItem
    var indent: CGFloat = 0

    @State private var open: Bool
    @Environment(\.agentLoadDetails) private var loadDetails

    init(item: AgentToolItem, indent: CGFloat = 0, startOpen: Bool = false) {
        self.item = item
        self.indent = indent
        _open = State(initialValue: startOpen)
    }
    private var loaded: Bool { !jcTrim(item.output).isEmpty }
    /// Output here, or on the server for a lite chat.
    private var hasOutput: Bool { loaded || item.detailIndex != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasOutput else { return }
                if !open, !loaded, let i = item.detailIndex { loadDetails(i) }
                withAnimation(.snappy(duration: 0.22)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    icon.frame(width: 18, height: 18)
                    Text(Self.sentence(item.line, failed: item.failed))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if hasOutput {
                        JcIcon("chevron.right", size: 10, weight: .semibold)
                            .foregroundStyle(JcTheme.muted.opacity(0.7))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.line.text + (item.failed ? ", failed" : ""))
            .accessibilityHint(hasOutput ? (open ? "Hides the output" : "Shows the output") : "")
            if open {
                Group {
                    if loaded {
                        AgentOutputBlock(text: item.output, failed: item.failed)
                    } else {
                        AgentDetailsLoading()
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .padding(.leading, 20 + indent)
        .padding(.trailing, 20)
    }

    @ViewBuilder private var icon: some View {
        if item.running {
            AgentSpinner(size: 12)
        } else if item.failed {
            JcIcon("exclamationmark.triangle", size: 13).foregroundStyle(JcTheme.danger)
        } else {
            JcIcon(item.line.symbol, size: 13).foregroundStyle(JcTheme.muted)
        }
    }

    /// The verb in the reading colour, what it acted on quieter — a command or
    /// a pattern in monospace.
    static func sentence(_ line: AgentToolLine, failed: Bool) -> AttributedString {
        var verb = AttributedString(line.object.isEmpty ? line.text : line.verb)
        verb.font = .system(size: 15, weight: .medium)
        verb.foregroundColor = failed ? JcTheme.danger : JcTheme.text.opacity(0.9)
        guard !line.object.isEmpty else { return verb }
        var object = AttributedString(" " + line.object)
        object.font = line.monospaced ? .system(size: 13.5, design: .monospaced) : .system(size: 15)
        object.foregroundColor = JcTheme.muted
        return verb + object
    }
}

/// A tool's output: monospace on the terminal ground, scrollable both ways.
struct AgentOutputBlock: View {
    let text: String
    var failed = false

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            Text(trimmed)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(failed ? JcTheme.danger.opacity(0.9) : CodingUI.paneMuted)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A long run of tool calls as one line — "Read 3 files, ran 2 commands" —
/// that opens to the rows themselves.
struct AgentToolGroupRow: View {
    let summary: String
    let items: [AgentToolItem]

    @State private var open = false
    private var failed: Int { items.filter(\.failed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    JcIcon("rectangle.split.3x1", size: 13)
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 18, height: 18)
                    Text(summary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text.opacity(0.9))
                        .lineLimit(1)
                    if failed > 0 {
                        Text("· \(failed) failed")
                            .font(.system(size: 13.5))
                            .foregroundStyle(JcTheme.danger)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    JcIcon("chevron.right", size: 10, weight: .semibold)
                        .foregroundStyle(JcTheme.muted.opacity(0.7))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityLabel("\(summary), \(items.count) steps")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        AgentToolRow(item: item, indent: 14)
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(JcTheme.glassBorder).frame(width: 1).padding(.leading, 28).padding(.vertical, 6)
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - File edits

/// A changed file: its name, its folder, +N −M, and a tap to its coloured diff.
struct AgentEditCard: View {
    let edit: AgentFileEdit
    var cwd = ""
    var openDiff: (AgentFileEdit) -> Void = { _ in }

    @State private var open: Bool
    @Environment(\.agentLoadDetails) private var loadDetails

    init(edit: AgentFileEdit, cwd: String = "", startOpen: Bool = false,
         openDiff: @escaping (AgentFileEdit) -> Void = { _ in }) {
        self.edit = edit
        self.cwd = cwd
        self.openDiff = openDiff
        _open = State(initialValue: startOpen)
    }
    static let previewLines = 40

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !open, edit.lines.isEmpty, let i = edit.detailIndex { loadDetails(i) }
                withAnimation(.snappy(duration: 0.24)) { open.toggle() }
            } label: {
                HStack(spacing: 11) {
                    JcIcon(edit.isNew ? "doc.text" : "pencil", size: 14)
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(edit.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        let folder = AgentsPresentation.folder(of: edit.path, cwd: cwd)
                        Text(edit.isNew ? (folder.isEmpty ? "New file" : "New file · \(folder)") : folder)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    Text("+\(edit.added)")
                        .foregroundStyle(CodingUI.diffAdd)
                    Text("−\(edit.removed)")
                        .foregroundStyle(CodingUI.diffDel)
                    JcIcon("chevron.right", size: 10, weight: .semibold)
                        .foregroundStyle(JcTheme.muted.opacity(0.7))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(edit.name), \(edit.added) lines added, \(edit.removed) removed")
            if open {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 0.5)
                if edit.lines.isEmpty && edit.detailIndex != nil {
                    AgentDetailsLoading().padding(.horizontal, 14)
                }
                AgentDiffLines(lines: Array(edit.lines.prefix(Self.previewLines)))
                if edit.lines.count > Self.previewLines || edit.truncated {
                    Button {
                        openDiff(edit)
                    } label: {
                        Text(edit.lines.count > Self.previewLines
                             ? "Show all \(edit.lines.count) lines" : "Some lines were left out to keep this small")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(edit.lines.count > Self.previewLines ? JcTheme.accent : JcTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(CodingUI.pane)
                    }
                    .buttonStyle(.plain)
                    .disabled(edit.lines.count <= Self.previewLines)
                }
            }
        }
        .background(JcTheme.glassFill, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }
}

/// Diff lines on the terminal ground: green adds, red removals, a dotted gap
/// between hunks. Scrolls sideways so a long line can't widen the card.
struct AgentDiffLines: View {
    let lines: [AgentDiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodingUI.pane)
    }

    @ViewBuilder private func row(_ line: AgentDiffLine) -> some View {
        switch line.kind {
        case .gap:
            Text("⋯")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        default:
            let (mark, color, ground): (String, Color, Color) = {
                switch line.kind {
                case .added: return ("+", CodingUI.diffAdd, CodingUI.diffAdd.opacity(0.12))
                case .removed: return ("−", CodingUI.diffDel, CodingUI.diffDel.opacity(0.12))
                default: return (" ", CodingUI.paneMuted, .clear)
                }
            }()
            HStack(spacing: 8) {
                Text(mark).foregroundStyle(color)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .context ? CodingUI.paneMuted.opacity(0.8) : CodingUI.paneText)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ground)
        }
    }
}

/// A file's whole diff, in a sheet.
struct AgentDiffView: View {
    let edit: AgentFileEdit

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                AgentDiffLines(lines: edit.lines)
                if edit.truncated {
                    Text("Some lines were left out to keep this small.")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .padding(12)
                }
            }
        }
        .background(CodingUI.pane.ignoresSafeArea())
    }
}

// MARK: - Live

/// The bottom row while the agent works: a spinner and what it's doing, the
/// words breathing gently. The pulse is drawn from the clock rather than an
/// animation, so new words swap in cleanly instead of morphing glyph by glyph.
struct AgentWorkingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            AgentSpinner(size: 13)
                .frame(width: 18, height: 18)
            TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text.opacity(0.62 + 0.22 * sin(t * 2.6)))
                    .lineLimit(1)
                    .contentTransition(.identity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Composer

/// The fixed composer: "Reply to Claude Code…" and a send button, on glass.
/// The edge glows while the agent works, as the Chat tab's does.
struct AgentComposer: View {
    let placeholder: String
    var working = false
    let onSend: (String) -> Void

    @State private var draft = ""
    /// Bumped on every send: a multi-line `TextField` keeps stale text on screen
    /// when its binding is cleared while focused, so the field is recreated.
    @State private var generation = 0
    @FocusState private var focused: Bool

    private var canSend: Bool { !jcTrim(draft).isEmpty }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft,
                      prompt: Text(placeholder).foregroundStyle(JcTheme.muted), axis: .vertical)
                .id(generation)
                .font(.body)
                .foregroundStyle(JcTheme.text)
                .tint(JcTheme.cyan)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .accessibilityLabel("Reply")
            Button(action: send) {
                JcIcon("arrow.up", size: 16, weight: .semibold)
                    .foregroundStyle(canSend ? JcTheme.accent : JcTheme.muted)
                    .frame(width: 40, height: 40)
                    .jcLiquidGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.smooth(duration: 0.2), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .jcLiquidGlass(in: shape)
        .jcBorderBeam(shape, active: working)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [JcTheme.bg.opacity(0), JcTheme.bg.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea())
    }

    private func send() {
        let text = jcTrim(draft)
        guard !text.isEmpty else { return }
        draft = ""
        generation += 1
        onSend(text)
    }
}
