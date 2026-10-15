import SwiftUI

/// One approval or question waiting on you, inline at the bottom of its
/// session (or on the list when its session isn't there). An approval offers
/// Allow, Always (Claude's own suggested rule, when it has one), Deny with an
/// optional note, and "answer in the terminal". Allow and Always need Face ID:
/// they decide what runs on the computer.
struct AgentRequestCard: View {
    let request: AgentRequest
    let store: AgentsStore
    var showsProject = true

    @State private var busy = false
    @State private var denying = false
    @State private var note = ""

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                PulsingDot(color: JcTheme.amber, size: 7)
                    .padding(.top, 7)
                Text(AgentsPresentation.approvalTitle(request))
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if showsProject && !request.project.isEmpty {
                    Text(request.project)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            if request.kind == .question {
                AgentQuestionForm(request: request, store: store)
            } else {
                approvalBody
            }
        }
        .padding(16)
        .background(JcTheme.surface, in: shape)
        .overlay(shape.strokeBorder(JcTheme.amber.opacity(0.35), lineWidth: 1))
        .disabled(busy)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var approvalBody: some View {
        Text(AgentToolPhrase.detail(tool: request.tool,
                                    summary: request.command.isEmpty ? request.summary : request.command))
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(CodingUI.paneText)
            .lineLimit(10)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .textSelection(.enabled)
        if denying {
            TextField("Tell it what to do instead (optional)", text: $note, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .padding(12)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                Button("Back") { denying = false }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, full: true))
                Button("Deny") { decide(.deny, message: note) }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
            }
        } else {
            HStack(spacing: 10) {
                Button("Allow") { decide(.allow, authenticate: true) }
                    .buttonStyle(.jcGlass(tint: JcTheme.success, full: true))
                if request.canAlways {
                    Button("Always") { decide(.always, authenticate: true) }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
                }
                Button("Deny") { denying = true }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
            }
            terminalButton { decide(.ask) }
        }
    }

    private func decide(_ decision: AgentsStore.Decision, message: String? = nil,
                        authenticate: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            if authenticate {
                let reason = "Allow \(request.agentName) to run this on your computer"
                guard await OwnerCheck.confirm(reason: reason) else { return }
            }
            await store.decide(request, decision, message: message)
        }
    }
}

/// "Answer in the terminal instead": hands the decision back to the computer.
private func terminalButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            JcIcon("terminal", size: 12)
            Text("Answer in the terminal instead")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(JcTheme.muted)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Let the terminal on the computer ask instead")
}

/// AskUserQuestion, answered from the phone: up to four questions, single or
/// multiple choice, with "Other" free text.
struct AgentQuestionForm: View {
    let request: AgentRequest
    let store: AgentsStore

    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var busy = false

    private var complete: Bool {
        request.questions.allSatisfy { q in
            !(picks[q.question] ?? []).isEmpty || !(other[q.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(request.questions) { q in
                VStack(alignment: .leading, spacing: 10) {
                    if !q.header.isEmpty {
                        Text(q.header)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Text(q.question)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(q.options.enumerated()), id: \.element.id) { i, option in
                            optionRow(q, option)
                            if i < q.options.count - 1 {
                                Rectangle().fill(JcTheme.glassBorder).frame(height: 0.5).padding(.leading, 42)
                            }
                        }
                    }
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    TextField("Something else…", text: Binding(
                        get: { other[q.question] ?? "" },
                        set: { other[q.question] = $0 }))
                        .font(.system(size: 15))
                        .padding(12)
                        .background(JcTheme.glassFill,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            Button("Send answer") { send(collect()) }
                .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
                .disabled(!complete || busy)
            terminalButton { send(nil) }
        }
    }

    private func optionRow(_ q: AgentQuestion, _ option: AgentOption) -> some View {
        let chosen = picks[q.question]?.contains(option.label) ?? false
        return Button {
            var set = picks[q.question] ?? []
            if q.multiSelect {
                if chosen { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = chosen ? [] : [option.label]
            }
            picks[q.question] = set
        } label: {
            HStack(alignment: .top, spacing: 12) {
                JcIcon(q.multiSelect ? (chosen ? "checkmark.circle.fill" : "circle")
                                     : (chosen ? "largecircle.fill.circle" : "circle"), size: 17)
                    .foregroundStyle(chosen ? JcTheme.accent : JcTheme.muted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 15, weight: .medium))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(JcTheme.text)
    }

    private func collect() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for q in request.questions {
            var chosen = Array(picks[q.question] ?? [])
            let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { chosen = q.multiSelect ? chosen + [typed] : [typed] }
            out[q.question] = chosen
        }
        return out
    }

    private func send(_ answers: [String: [String]]?) {
        busy = true
        Task {
            defer { busy = false }
            if let answers {
                await store.answer(request, answers)
            } else {
                await store.decide(request, .ask)
            }
        }
    }
}
