import SwiftUI

/// "Waiting on you": the amber used across Jarvis.
let islandAmber = Color(red: 0.98, green: 0.75, blue: 0.14)

/// The island: a black shape hanging from the notch. Compact, it's the notch
/// with two ears — the orb on the left, what's waiting or working on the right.
/// Expanded, it shows what waits on you first (approval / question cards you
/// answer right here), then every session with its current step; a session
/// opens on its recent steps and changed files.
struct IslandRootView: View {
    let model: AppModel
    let ui: IslandUI
    let controller: IslandController

    static let expandedWidth: CGFloat = 560

    @MainActor
    static func expandedHeight(model: AppModel, tab: IslandTab = .agents) -> CGFloat {
        if tab != .agents { return tab.height }
        var h: CGFloat = 92
        if model.pending.first != nil { h += model.pending.first!.isQuestion ? 230 : 150 }
        h += CGFloat(min(model.sessions.count, 4)) * 54
        if model.flash != nil { h += 44 }
        return min(max(h, 160), 500)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: ui.state == .expanded ? 24 : 12,
                                           bottomTrailingRadius: ui.state == .expanded ? 24 : 12)
                        .fill(Color.black))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: ui.state == .expanded ? 24 : 12,
                                                  bottomTrailingRadius: ui.state == .expanded ? 24 : 12))
                .shadow(color: .black.opacity(ui.state == .expanded ? 0.45 : 0), radius: 14, y: 6)
            Spacer(minLength: 0)
        }
        .frame(width: IslandController.panelSize.width, height: IslandController.panelSize.height, alignment: .top)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch ui.state {
        case .hidden:
            Color.clear.frame(width: ui.geometry.width, height: ui.geometry.height)
        case .compact:
            compact
        case .expanded:
            ExpandedIsland(model: model, ui: ui, controller: controller)
                .frame(width: Self.expandedWidth)
                .frame(maxHeight: Self.expandedHeight(model: model, tab: ui.tab), alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            Group {
                if MusicController.shared.now?.isPlaying == true, model.mood == .idle {
                    // The orb moves with the music: a soft beat while something plays.
                    TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        OrbView(mood: .idle, skin: OrbSkin.current, size: max(12, ui.geometry.height - 14),
                                beat: 0.5 + 0.5 * sin(t * 2 * .pi * 0.9))
                            .animation(.easeInOut(duration: 0.25), value: t)
                    }
                } else {
                    OrbView(mood: model.connected ? model.mood : .idle, skin: OrbSkin.current,
                            size: max(12, ui.geometry.height - 14))
                }
            }
            .frame(width: IslandController.earWidth)
            Spacer().frame(width: ui.geometry.width)
            Group {
                if model.waitingCount > 0 {
                    Text("\(model.waitingCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.98, green: 0.75, blue: 0.14)))
                } else if model.workingCount > 0 {
                    ProgressView().controlSize(.mini).tint(Color(red: 0.2, green: 0.83, blue: 0.6))
                } else if let five = model.usage?.fiveHour {
                    Text("\(five)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: IslandController.earWidth)
        }
        .frame(width: ui.compactWidth, height: ui.geometry.height)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggle() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            IslandDrop.take(providers) { controller.open(.chat) }
        }
    }
}

/// Files dropped on the island go to the chat.
enum IslandDrop {
    static func take(_ providers: [NSItemProvider], then open: @escaping @MainActor () -> Void) -> Bool {
        var took = false
        for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
            took = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    MacChatStore.shared.attach([url])
                    open()
                }
            }
        }
        return took
    }
}

private struct ExpandedIsland: View {
    let model: AppModel
    let ui: IslandUI
    let controller: IslandController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabs
            switch ui.tab {
            case .agents: agents
            case .chat: ChatPane(ui: ui)
            case .services: ServicesPane(model: model)
            case .music: MusicPane()
            case .mail: MailPane(ui: ui)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, ui.geometry.height + 8)
        .padding(.bottom, 14)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            IslandDrop.take(providers) { ui.tab = .chat }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases) { t in
                Button { withAnimation(.easeOut(duration: 0.18)) { ui.tab = t } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 11, weight: .semibold))
                        if ui.tab == t { Text(t.title).font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(ui.tab == t ? JcAccent.color.opacity(0.22) : .white.opacity(0.06)))
                    .foregroundStyle(ui.tab == t ? JcAccent.color : .white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
            Spacer()
            if ui.tab != .agents, model.waitingCount > 0 {
                Button { ui.tab = .agents } label: {
                    Text("\(model.waitingCount) waiting").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.98, green: 0.75, blue: 0.14)))
                }
                .buttonStyle(.plain)
            }
            Button { controller.close() } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder private var agents: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.connected {
                Text("Jarvis isn't running on this Mac — start it with `jc-client start`.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            if let flash = model.flash {
                FlashRow(session: flash)
            }
            if let p = model.pending.first {
                // Keyed by the request: a card that replaces another starts fresh
                // (no carried-over deny note) and ignores clicks for a moment.
                if p.isQuestion {
                    QuestionCard(pending: p, model: model, ui: ui).id(p.fingerprint)
                } else {
                    ApprovalCard(pending: p, model: model, ui: ui, extra: model.pending.count - 1).id(p.fingerprint)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    if model.sessions.isEmpty && model.connected {
                        Text("No agent sessions. Start Claude Code (or Codex, Gemini…) and it shows up here.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.sessions) { s in
                        SessionRow(session: s, selected: model.selectedKey == s.key)
                            .onTapGesture {
                                model.selectedKey = model.selectedKey == s.key ? nil : s.key
                            }
                        if model.selectedKey == s.key {
                            SessionDetail(session: s)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OrbView(mood: model.mood, skin: OrbSkin.current, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agents").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text(summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let u = model.usage {
                UsagePill(label: "5h", pct: u.fiveHour)
                UsagePill(label: "wk", pct: u.sevenDay)
            }
            if let c = model.codexUsage {
                UsagePill(label: "Codex", pct: c.fiveHour ?? c.sevenDay)
                    .help("Codex plan: \(c.fiveHour.map { "5h \($0)%, " } ?? "")week \(c.sevenDay.map { "\($0)%" } ?? "–")")
            }
            Button { TerminalTarget.activate(session: model.selected) } label: {
                Image(systemName: "terminal").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
            .help("Jump to the session's terminal (⌃⌥T)")
        }
    }

    private var summary: String {
        if model.waitingCount > 0 { return "\(model.waitingCount) waiting on you" }
        if model.workingCount > 0 { return "\(model.workingCount) working" }
        return "\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")"
    }
}

private struct UsagePill: View {
    let label: String
    let pct: Int?

    var body: some View {
        let p = pct ?? 0
        let color: Color = p < 50 ? .green : p < 80 ? .orange : .red
        Text(pct.map { "\(label) \($0)%" } ?? "\(label) –")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

private func stateColor(_ s: MacState) -> Color {
    switch s {
    case .working, .thinking: return Color(red: 0.2, green: 0.83, blue: 0.6)
    case .approval, .question: return Color(red: 0.98, green: 0.75, blue: 0.14)
    case .finished: return JcAccent.color
    case .error: return .red
    case .ratelimit: return .orange
    case .idle: return .gray
    }
}

private struct SessionRow: View {
    let session: MacSession
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(stateColor(session.state)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("\(session.agentName) · \(session.state.label)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                if !session.step.isEmpty {
                    Text(session.step).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : 0.05)))
        .contentShape(Rectangle())
    }
}

private struct SessionDetail: View {
    let session: MacSession
    @State private var openFile: MacFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.prompt.isEmpty {
                Text(session.prompt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
            }
            ForEach(Array(session.steps.suffix(5).enumerated()), id: \.offset) { _, step in
                Text("› \(step)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            ForEach(session.files) { f in
                Button { openFile = openFile == f ? nil : f } label: {
                    HStack {
                        Image(systemName: "doc.text").font(.system(size: 10))
                        Text(f.name).font(.system(size: 11))
                        Spacer()
                        Text("+\(f.added)").foregroundStyle(.green).font(.system(size: 10, design: .monospaced))
                        Text("−\(f.removed)").foregroundStyle(.red).font(.system(size: 10, design: .monospaced))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                if openFile == f {
                    DiffBox(file: f)
                }
            }
            HStack {
                Button("Terminal") { TerminalTarget.activate(session: session) }
                Spacer()
            }
            .buttonStyle(IslandButtonStyle(tint: .white.opacity(0.8)))
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

private struct DiffBox: View {
    let file: MacFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    Text("\(String(line.kind)) \(line.text)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(line.kind == "+" ? Color.green : line.kind == "-" ? Color.red : Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 140)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}

private struct FlashRow: View {
    let session: MacSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.state == .error ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(session.state == .error ? .red : .green)
            Text("\(session.project): \(session.state == .error ? "failed" : "done")")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            if !session.final.isEmpty {
                Text(session.final).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.30 : 0.16)))
    }
}

/// An approval: the exact command, Allow (Y) / Always / Deny (N) / Terminal.
private struct ApprovalCard: View {
    let pending: MacPending
    let model: AppModel
    let ui: IslandUI
    var extra = 0

    @State private var denying = false
    @State private var note = ""
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(islandAmber)
                Text("\(pending.project) — \(pending.agent == "claude" ? "Claude" : pending.agent.capitalized) needs approval")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(islandAmber)
                Spacer()
                if extra > 0 { Text("+\(extra)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
            }
            Text(pending.command.isEmpty ? pending.summary : pending.command)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                .lineLimit(5).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            if denying {
                HStack {
                    TextField("Tell it what to do instead (optional)", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.decide(pending, "deny", message: note); Sounds.play(.decided) }
                    Button("Deny") { model.decide(pending, "deny", message: note); Sounds.play(.decided) }
                }
                .buttonStyle(IslandButtonStyle(tint: .red))
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { model.decide(pending, "allow"); Sounds.play(.decided) }
                        .buttonStyle(IslandButtonStyle(tint: .green)).keyboardShortcut("y", modifiers: [])
                    if pending.canAlways {
                        Button("Always") { model.decide(pending, "always"); Sounds.play(.decided) }
                            .buttonStyle(IslandButtonStyle(tint: JcAccent.color))
                    }
                    Button("Deny") { denying = true; ui.pinned = true }
                        .buttonStyle(IslandButtonStyle(tint: .red)).keyboardShortcut("n", modifiers: [])
                    Spacer()
                    Button("Terminal") { model.decide(pending, "ask") }
                        .buttonStyle(IslandButtonStyle(tint: .white.opacity(0.7)))
                        .help("Let the terminal ask instead")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(islandAmber.opacity(0.08)))
        .disabled(!armed)
        .task {
            try? await Task.sleep(for: .seconds(ArmGate.delay))
            armed = true
        }
        .onDisappear { ui.pinned = false }
    }
}

/// A question (AskUserQuestion): choose, multi-select, or type "Other".
private struct QuestionCard: View {
    let pending: MacPending
    let model: AppModel
    let ui: IslandUI

    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var armed = false

    /// Every question has a pick or a typed answer.
    private var complete: Bool {
        pending.questions.allSatisfy { q in
            !(picks[q.question] ?? []).isEmpty
                || !(other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(islandAmber)
                Text("\(pending.project) has a question").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(islandAmber)
                Spacer()
            }
            ForEach(pending.questions) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    FlowOptions(question: q, picks: Binding(get: { picks[q.question] ?? [] },
                                                            set: { picks[q.question] = $0 }))
                    TextField("Other…", text: Binding(get: { other[q.question] ?? "" },
                                                     set: { other[q.question] = $0; ui.pinned = true }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
            }
            HStack {
                Button("Terminal") { model.decide(pending, "ask") }
                    .buttonStyle(IslandButtonStyle(tint: .white.opacity(0.7)))
                Spacer()
                Button("Send answer") { send() }
                    .buttonStyle(IslandButtonStyle(tint: JcAccent.color))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!complete)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(islandAmber.opacity(0.08)))
        .disabled(!armed)
        .task {
            try? await Task.sleep(for: .seconds(ArmGate.delay))
            armed = true
        }
        .onDisappear { ui.pinned = false }
    }

    private func send() {
        var answers: [String: Any] = [:]
        for q in pending.questions {
            var chosen = Array(picks[q.question] ?? [])
            let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { chosen = q.multiSelect ? chosen + [typed] : [typed] }
            guard !chosen.isEmpty else { continue }
            answers[q.question] = q.multiSelect ? chosen : chosen[0]
        }
        model.decide(pending, "answer", answers: answers)
        Sounds.play(.decided)
    }
}

private struct FlowOptions: View {
    let question: MacQuestion
    @Binding var picks: Set<String>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, label in
                let on = picks.contains(label)
                Button {
                    if question.multiSelect {
                        if on { picks.remove(label) } else { picks.insert(label) }
                    } else {
                        picks = on ? [] : [label]
                    }
                } label: {
                    Text(label).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(on ? JcAccent.color.opacity(0.35)
                                                      : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .help(question.details.indices.contains(i) ? question.details[i] : "")
            }
        }
    }
}
