import SwiftUI

/// One approval or question waiting on you. An approval offers Allow, Always
/// (Claude's own suggested rule, when it has one), Deny with an optional note,
/// and "Terminal" (let the terminal ask). Allow and Always need Face ID.
struct AgentRequestCard: View {
    let request: AgentRequest
    let store: AgentsStore

    @State private var busy = false
    @State private var denying = false
    @State private var note = ""

    private var tint: Color { CodingUI.waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                JcIcon(request.kind == .question ? "questionmark.bubble" : "lock", size: 14)
                    .foregroundStyle(tint)
                Text(request.kind == .question ? "\(request.agentName) has a question"
                                               : "\(request.agentName) needs approval")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text(request.project)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            if request.kind == .question {
                AgentQuestionForm(request: request, store: store)
            } else {
                approvalBody
            }
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .disabled(busy)
    }

    @ViewBuilder private var approvalBody: some View {
        Text(request.command.isEmpty ? request.summary : request.command)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(CodingUI.paneText)
            .lineLimit(8)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .textSelection(.enabled)
        if denying {
            TextField("Tell it what to do instead (optional)", text: $note, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .padding(10)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Back") { denying = false }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                Spacer()
                Button("Deny") { decide(.deny, message: note) }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
            }
        } else {
            HStack(spacing: 8) {
                Button("Allow") { decide(.allow, authenticate: true) }
                    .buttonStyle(.jcGlass(tint: JcTheme.success, compact: true))
                if request.canAlways {
                    Button("Always") { decide(.always, authenticate: true) }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                }
                Button("Deny") { denying = true }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                Spacer(minLength: 0)
                Button("Terminal") { decide(.ask) }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                    .accessibilityHint("Let the terminal on the computer ask instead")
            }
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
        VStack(alignment: .leading, spacing: 14) {
            ForEach(request.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if !q.header.isEmpty {
                        Text(q.header.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Text(q.question).font(.system(size: 15, weight: .medium))
                    ForEach(q.options) { option in
                        optionRow(q, option)
                    }
                    TextField("Other…", text: Binding(
                        get: { other[q.question] ?? "" },
                        set: { other[q.question] = $0 }))
                        .font(.system(size: 14))
                        .padding(9)
                        .background(JcTheme.glassFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack {
                Button("Terminal") { send(nil) }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                Spacer()
                Button("Send answer") { send(collect()) }
                    .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    .disabled(!complete || busy)
            }
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: q.multiSelect ? (chosen ? "checkmark.square.fill" : "square")
                                                : (chosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(chosen ? JcTheme.accent : JcTheme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 14, weight: .medium))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
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
