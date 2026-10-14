import SwiftUI

/// One agent session: what it's doing now, its last turn (the prompt, every
/// action with its output, the files it changed with their diffs, its answer),
/// and a box to send the next instruction. Refreshes when the session's hooks
/// report something new (the store hears the `agents` push).
struct AgentSessionScreen: View {
    let key: String
    let store: AgentsStore

    @Environment(AppRouter.self) private var router
    @State private var detail: AgentSessionDetail?
    @State private var error: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var sent: String?
    @State private var openFile: AgentFileDiff?

    private var live: AgentSessionItem? { store.session(key: key) ?? detail?.item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = live { header(s) }
                if let s = live, let request = store.request(for: s) {
                    AgentRequestCard(request: request, store: store)
                }
                if let s = live, !s.steps.isEmpty { stepsCard(s) }
                if let turn = detail?.turn {
                    AgentLastTurnView(turn: turn) { openFile = $0 }
                }
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
                }
                composer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 100)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(live?.project ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if live?.codingSessionId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.openMore(.coding) } label: { JcIcon("terminal", size: 17) }
                        .accessibilityLabel("Terminal and transcript")
                }
            }
        }
        .task { await load() }
        .onChange(of: store.session(key: key)?.lastEventAt) { _, _ in
            Task { await load() }
        }
        .sheet(item: $openFile) { file in
            NavigationStack {
                AgentDiffView(file: file)
                    .navigationTitle(file.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { openFile = nil } }
                    }
            }
        }
    }

    private func load() async {
        do {
            detail = try await store.detail(key: key)
            error = nil
        } catch {
            if detail == nil { self.error = apiErrorMessage(error) }
        }
    }

    private func header(_ s: AgentSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(AgentStyle.color(s.state)).frame(width: 9, height: 9)
                Text(s.state.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentStyle.color(s.state))
                Spacer()
                Text("since \(s.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
            Text([s.agentName, s.hostApp, s.model].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            Text(s.cwd).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(JcTheme.muted).lineLimit(1).truncationMode(.head)
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepsCard(_ s: AgentSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOW").font(.system(size: 11, weight: .semibold)).foregroundStyle(JcTheme.muted)
            ForEach(Array(s.steps.suffix(6).enumerated()), id: \.offset) { i, step in
                let last = i == min(5, s.steps.count - 1)
                Text(step.text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(last ? JcTheme.text : JcTheme.muted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEXT INSTRUCTION").font(.system(size: 11, weight: .semibold)).foregroundStyle(JcTheme.muted)
            TextField("Tell it what to do next…", text: $draft, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(12)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                if let sent {
                    Text(sent).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
                Spacer()
                Button(sending ? "Sending…" : "Send") { send() }
                    .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            guard await OwnerCheck.confirm(reason: "Send this instruction to your computer") else { return }
            do {
                let via = try await store.sendInstruction(text, to: key)
                draft = ""
                sent = via == "resume" ? "Sent — your Mac is continuing the conversation."
                                       : "Typed into the session."
                error = nil
            } catch {
                self.error = apiErrorMessage(error)
            }
        }
    }
}

/// The last turn, the way you'd want to read it on a phone.
struct AgentLastTurnView: View {
    let turn: AgentTurn
    let openFile: (AgentFileDiff) -> Void

    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LAST TURN").font(.system(size: 11, weight: .semibold)).foregroundStyle(JcTheme.muted)
                Spacer()
                if let d = turn.duration {
                    Text(Duration.seconds(d).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            if !turn.prompt.isEmpty {
                Text(turn.prompt)
                    .font(.system(size: 14))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(JcTheme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ForEach(turn.actions) { action in actionRow(action) }
            if !turn.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FILES").font(.system(size: 11, weight: .semibold)).foregroundStyle(JcTheme.muted)
                    ForEach(turn.files) { file in
                        Button { openFile(file) } label: {
                            HStack {
                                JcIcon("doc.text", size: 13).foregroundStyle(JcTheme.muted)
                                Text(file.name).font(.system(size: 14)).foregroundStyle(JcTheme.text)
                                Spacer()
                                Text("+\(file.added)").font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(CodingUI.diffAdd)
                                Text("−\(file.removed)").font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(CodingUI.diffDel)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !turn.final.isEmpty {
                Text(LocalizedStringKey(turn.final))
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func actionRow(_ action: AgentAction) -> some View {
        let open = expanded.contains(action.index)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if open { expanded.remove(action.index) } else { expanded.insert(action.index) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: action.failed ? "exclamationmark.triangle.fill" : AgentTurnStyle.icon(action.tool))
                        .font(.system(size: 12))
                        .foregroundStyle(action.failed ? JcTheme.danger : JcTheme.muted)
                        .frame(width: 16)
                    Text(action.summary.isEmpty ? action.tool : action.summary)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(JcTheme.text.opacity(0.9))
                        .lineLimit(open ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if open, !action.output.isEmpty {
                Text(action.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CodingUI.paneMuted)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
            }
        }
    }
}

enum AgentTurnStyle {
    static func icon(_ tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text.magnifyingglass"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "gearshape"
        }
    }
}

/// A file's diff, line by line, with the gaps between hunks.
struct AgentDiffView: View {
    let file: AgentFileDiff

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
                if file.truncated {
                    Text("… the rest was left out to keep this small")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted).padding(10)
                }
            }
            .padding(.vertical, 8)
        }
        .background(CodingUI.pane.ignoresSafeArea())
    }

    @ViewBuilder private func row(_ line: AgentDiffLine) -> some View {
        switch line.kind {
        case .gap:
            Text("⋯").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(JcTheme.muted).padding(.horizontal, 10).padding(.vertical, 4)
        default:
            let (mark, color, bg): (String, Color, Color) = {
                switch line.kind {
                case .added: return ("+", CodingUI.diffAdd, CodingUI.diffAdd.opacity(0.12))
                case .removed: return ("−", CodingUI.diffDel, CodingUI.diffDel.opacity(0.12))
                default: return (" ", CodingUI.paneMuted, .clear)
                }
            }()
            HStack(spacing: 8) {
                Text(mark).foregroundStyle(color)
                Text(line.text).foregroundStyle(line.kind == .context ? CodingUI.paneMuted : CodingUI.paneText)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
        }
    }
}
