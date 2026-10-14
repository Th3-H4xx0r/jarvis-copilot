import SwiftUI

/// The Agents tab: every coding agent session on the Mac and the server, live
/// from their hooks — what waits on you first, then what's working, then the
/// rest. Approvals and questions are answered right here.
struct AgentsPage: View {
    var store: AgentsStore = .shared
    @Environment(AppRouter.self) private var router
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header
                    if let error = store.loadError, store.sessions.isEmpty {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.danger)
                            .padding(.horizontal, 4)
                    }
                    ForEach(store.requests) { request in
                        AgentRequestCard(request: request, store: store)
                    }
                    if store.sessions.isEmpty {
                        if store.loaded { emptyState }
                    } else {
                        ForEach(store.sessions) { session in
                            NavigationLink(value: session.key) {
                                AgentRow(session: session, waiting: store.request(for: session) != nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .refreshable { await store.refresh() }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Agents")
            .navigationDestination(for: String.self) { key in
                AgentSessionScreen(key: key, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        AgentsHistoryView()
                    } label: {
                        JcIcon("clock.arrow.circlepath", size: 17)
                    }
                    .accessibilityLabel("History")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.openMore(.coding)
                    } label: {
                        JcIcon("terminal", size: 17)
                    }
                    .accessibilityLabel("Projects, terminals and new sessions")
                }
            }
        }
        .onTabVisibilityChange(.agents) { store.setVisible($0) }
        .onChange(of: store.openRequest, initial: true) { _, _ in
            if let key = store.consumeOpen() { path = [key] }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text("\(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
            }
            Spacer()
            if let usage = store.usage {
                AgentPlanRings(usage: usage)
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private var summaryLine: String {
        let waiting = store.waitingCount
        let working = store.workingCount
        if waiting > 0 { return "\(waiting) waiting on you" }
        if working > 0 { return "\(working) working" }
        return store.sessions.isEmpty ? "No agents running" : "All quiet"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No agent sessions yet")
                .font(.system(size: 16, weight: .semibold))
            Text("Start Claude Code (or Codex, Gemini, Cursor…) on your Mac. If nothing shows up, turn on agent tracking in the Jarvis app on the Mac, or run `jc-client hooks install` there.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }
}

/// One session: the agent and its state, the project, where it runs, and what
/// it's doing right now.
struct AgentRow: View {
    let session: AgentSessionItem
    var waiting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(AgentStyle.color(session.state))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .shadow(color: AgentStyle.color(session.state).opacity(0.6), radius: session.state == .working ? 4 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(AgentStyle.since(session.lastEventAt))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                if !session.step.isEmpty {
                    Text(session.step)
                        .font(.system(size: 13, design: session.state == .working ? .monospaced : .default))
                        .foregroundStyle(waiting ? CodingUI.waiting : JcTheme.text.opacity(0.85))
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.project), \(session.agentName), \(session.state.label)")
    }

    private var subtitle: String {
        var parts = [session.agentName, session.state.label]
        if !session.hostApp.isEmpty { parts.append(session.hostApp) }
        if session.subagents > 0 { parts.append("\(session.subagents) subagent\(session.subagents == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// The Claude plan's two limits: 5 hours (inner) and the week (outer).
struct AgentPlanRings: View {
    let usage: AgentPlanUsage

    var body: some View {
        HStack(spacing: 10) {
            ring(usage.fiveHour, label: "5h")
            ring(usage.sevenDay, label: "Week")
        }
    }

    private func ring(_ window: AgentPlanWindow?, label: String) -> some View {
        let pct = window?.percent ?? 0
        return VStack(spacing: 3) {
            ZStack {
                Circle().stroke(JcTheme.glassBorder, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(pct) / 100)
                    .stroke(AgentStyle.usageColor(pct), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(window == nil ? "–" : "\(pct)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
            }
            .frame(width: 34, height: 34)
            Text(label).font(.system(size: 10)).foregroundStyle(JcTheme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) limit \(pct) percent used")
    }
}

enum AgentStyle {
    static func color(_ state: AgentState) -> Color {
        switch state {
        case .working, .thinking: return CodingUI.green
        case .approval, .question: return CodingUI.waiting
        case .finished: return JcTheme.accent
        case .error: return JcTheme.danger
        case .ratelimit: return JcTheme.amber
        case .idle: return CodingUI.grey
        }
    }

    static func usageColor(_ pct: Int) -> Color {
        pct < 50 ? JcTheme.success : pct < 80 ? JcTheme.amber : JcTheme.danger
    }

    static func since(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
