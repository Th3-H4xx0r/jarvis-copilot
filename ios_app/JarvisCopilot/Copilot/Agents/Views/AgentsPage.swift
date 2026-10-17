import SwiftUI

/// Where the Agents tab's stack can go.
enum AgentsRoute: Hashable {
    /// A conversation, by its `agent|session_id` key.
    case session(String)
    case history
    case settings
}

/// The Agents tab: every coding-agent conversation on the Mac and the server,
/// one record each, live from their hooks. Top to bottom: the plan usage, the
/// Mac-asleep card when a Mac left sessions behind, what needs you (a flat
/// list across projects and machines), then every other session in
/// collapsible project groups. Approvals and questions are answered inside
/// each session; "+" starts a new one.
struct AgentsPage: View {
    var store: AgentsStore = .shared
    @Environment(AppRouter.self) private var router
    @State private var path: [AgentsRoute] = []
    @State private var showRecap = false
    @State private var showLaunch = false
    @AppStorage(AgentsListPrefs.collapsedKey) private var collapsedRaw = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.usage != nil || store.codexUsage != nil {
                        AgentUsageStrip(claude: store.usage, codex: store.codexUsage)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                    }
                    if let card = store.card {
                        AgentsSleepCard(card: card, store: store)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                    }
                    content
                }
                .padding(.bottom, 28)
            }
            .refreshable { await store.refresh() }
            .background(JcTheme.bg.ignoresSafeArea())
            .loadErrorBanner(store.loadError, hasContent: !store.isEmpty)
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showLaunch = true } label: {
                        JcIcon("plus", size: 17, weight: .semibold).foregroundStyle(JcTheme.text)
                    }
                    .accessibilityLabel("New session")
                    menu
                }
            }
            .navigationDestination(for: AgentsRoute.self) { route in
                switch route {
                case .session(let ckey):
                    AgentSessionScreen(ckey: ckey, store: store,
                                       navigate: { path.append($0) },
                                       showRecap: { showRecap = true })
                case .history:
                    AgentsHistoryView()
                case .settings:
                    CodeMasterSettingsPage()
                }
            }
        }
        .onTabVisibilityChange(.agents) { store.setVisible($0) }
        .onChange(of: "\(store.openRequest ?? "")|\(store.loaded)", initial: true) { _, _ in
            // A push tap can name its session before the first list is in;
            // wait for it so the tracker key resolves to its conversation.
            guard store.openRequest != nil, store.loaded, let key = store.consumeOpen() else { return }
            path = [.session(store.resolveCkey(key))]
        }
        .onChange(of: store.recapRequested, initial: true) { _, _ in
            if store.consumeRecap() { showRecap = true }
        }
        .sheet(isPresented: $showRecap) {
            AgentsRecapView(api: store.api)
        }
        .sheet(isPresented: $showLaunch) {
            AgentLaunchSheet(store: store)
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        let needs = store.needsYou
        let orphans = store.orphanRequests
        let projects = store.projects
        if !store.loaded {
            AgentsSkeletonList()
        } else if needs.isEmpty && orphans.isEmpty && projects.isEmpty {
            if let error = store.loadError {
                AgentsErrorState(message: error) { Task { await store.refresh() } }
            } else if store.card == nil {
                AgentsEmptyState { showLaunch = true }
            }
        } else {
            if !needs.isEmpty || !orphans.isEmpty {
                AgentSectionHeader(title: "Needs you", count: store.waitingCount)
                ForEach(orphans) { request in
                    AgentRequestCard(request: request, store: store)
                        .padding(.bottom, 10)
                }
                rows(needs, showsProject: true)
            }
            if !projects.isEmpty {
                AgentSectionHeader(title: "Projects")
                let collapsed = AgentsListLayout.collapsed(from: collapsedRaw)
                ForEach(projects) { group in
                    let open = AgentsListLayout.isExpanded(group, collapsed: collapsed, needsYou: needs)
                    AgentsProjectHeader(group: group, open: open,
                                        waiting: AgentsListLayout.hasWaiting(group, needsYou: needs)) {
                        toggle(group, collapsed: collapsed)
                    }
                    if open { rows(group.sessions, showsProject: false) }
                }
            }
        }
    }

    private func rows(_ convs: [AgentConv], showsProject: Bool) -> some View {
        ForEach(Array(convs.enumerated()), id: \.element.id) { index, conv in
            NavigationLink(value: AgentsRoute.session(conv.ckey)) {
                AgentSessionRow(conv: conv, request: store.request(for: conv), showsProject: showsProject)
            }
            .buttonStyle(AgentRowButtonStyle())
            if index < convs.count - 1 {
                Rectangle().fill(JcTheme.glassBorder)
                    .frame(height: 0.5)
                    .padding(.leading, 52)
            }
        }
    }

    /// Remembers how a group was left. A group with something waiting in it
    /// stays open regardless, and goes back to this once nothing waits.
    private func toggle(_ group: AgentProjectGroup, collapsed: Set<String>) {
        var next = collapsed
        if next.contains(group.id) { next.remove(group.id) } else { next.insert(group.id) }
        withAnimation(.snappy(duration: 0.25)) { collapsedRaw = AgentsListLayout.encode(next) }
    }

    private var menu: some View {
        Menu {
            Button { path.append(.history) } label: { Label("History", jcIcon: "clock.arrow.circlepath") }
            Button { showRecap = true } label: { Label("This week’s recap", jcIcon: "chart.line.uptrend.xyaxis") }
            Divider()
            Button { path.append(.settings) } label: { Label("Code Master settings", jcIcon: "gearshape") }
        } label: {
            JcIcon("ellipsis", size: 17)
                .foregroundStyle(JcTheme.text)
        }
        .accessibilityLabel("More")
    }
}

// MARK: - Rows

/// One conversation: its status mark, the task, then agent · where it runs
/// (with the project under Needs you), and what it waits on or is doing.
struct AgentSessionRow: View {
    let conv: AgentConv
    var request: AgentRequest?
    var showsProject = false

    private var status: AgentRowStatus { AgentsListLayout.status(conv, request: request) }
    private var subtitle: String { AgentsListLayout.subtitle(conv, showsProject: showsProject) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AgentStatusMark(status: status)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(conv.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(conv.status == .ended ? JcTheme.text.opacity(0.7) : JcTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(AgentsPresentation.time(conv.lastEventAt))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(JcTheme.muted)
                }
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                if let detail = AgentsListLayout.detail(conv, request: request) {
                    Text(detail.text)
                        .font(.system(size: 13.5, weight: detail.tone == .waiting ? .medium : .regular))
                        .foregroundStyle(Self.color(detail.tone))
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conv.title), \(subtitle), " + AgentsListLayout.statusLabel(conv, request: request))
    }

    static func color(_ tone: AgentRowDetail.Tone) -> Color {
        switch tone {
        case .waiting: return JcTheme.amber
        case .working: return JcTheme.text.opacity(0.7)
        case .failed: return JcTheme.danger
        case .quiet: return JcTheme.muted
        }
    }
}

/// A list row's press: a soft wash instead of the system's grey flash.
struct AgentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct AgentSectionHeader: View {
    let title: String
    var count: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JcTheme.muted)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(JcTheme.muted.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The quiet status mark: a spinner while it works, a check when it finished,
/// an amber dot while it waits on you.
struct AgentStatusMark: View {
    let status: AgentRowStatus
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch status {
            case .working:
                AgentSpinner(size: size * 0.9)
            case .waiting:
                PulsingDot(color: JcTheme.amber, size: size * 0.6)
            case .finished:
                JcIcon("checkmark.circle.fill", size: size * 0.92).foregroundStyle(status.color)
            case .failed:
                JcIcon("exclamationmark.circle.fill", size: size * 0.92).foregroundStyle(status.color)
            case .rateLimited:
                JcIcon("clock", size: size * 0.86).foregroundStyle(status.color)
            case .idle:
                Circle().strokeBorder(status.color, lineWidth: 1.5).frame(width: size * 0.56, height: size * 0.56)
            case .paused:
                JcIcon("moon.fill", size: size * 0.8).foregroundStyle(status.color)
            case .moving:
                AgentSpinner(size: size * 0.9, color: status.color)
            case .ended:
                JcIcon("stop.circle", size: size * 0.92).foregroundStyle(status.color)
            }
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityHidden(true)
    }
}

/// A thin rotating arc in the accent.
struct AgentSpinner: View {
    var size: CGFloat = 14
    var color: Color = JcTheme.accent
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.6, size * 0.13), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Plan usage

/// The plan limits as Claude Code (and Codex) report them: a slim card with
/// two rings per agent — 5 hours and the week — and when the 5 hours reset.
struct AgentUsageStrip: View {
    let claude: AgentPlanUsage?
    let codex: AgentPlanUsage?

    var body: some View {
        VStack(spacing: 0) {
            if let claude { row("Claude", claude) }
            if claude != nil && codex != nil {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 0.5).padding(.horizontal, 14)
            }
            if let codex { row("Codex", codex) }
        }
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
    }

    private func row(_ name: String, _ usage: AgentPlanUsage) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text(Self.resetLine(usage))
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentPlanRings(usage: usage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "5-hour limit resets 3:40 PM", or the week's when that's all there is.
    static func resetLine(_ u: AgentPlanUsage, now: Date = Date()) -> String {
        if let w = u.fiveHour, w.resetsAt > now {
            return "5-hour limit resets \(w.resetsAt.formatted(date: .omitted, time: .shortened))"
        }
        if let w = u.sevenDay, w.resetsAt > now {
            return "Weekly limit resets \(w.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return "Plan limits"
    }
}

/// A plan's two limits: 5 hours and the week, as small rings.
struct AgentPlanRings: View {
    let usage: AgentPlanUsage

    /// "Codex · 5h 12% · week 40%", with only the windows Codex reports.
    static func codexLine(_ u: AgentPlanUsage) -> String? {
        var parts: [String] = []
        if let w = u.fiveHour { parts.append("5h \(w.percent)%") }
        if let w = u.sevenDay { parts.append("week \(w.percent)%") }
        return parts.isEmpty ? nil : (["Codex"] + parts).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ring(usage.fiveHour, label: "5h")
            ring(usage.sevenDay, label: "Week")
        }
    }

    private func ring(_ window: AgentPlanWindow?, label: String) -> some View {
        let pct = window?.percent ?? 0
        return HStack(spacing: 7) {
            ZStack {
                Circle().stroke(JcTheme.glassBorder, lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat(pct) / 100)
                    .stroke(AgentStyle.usageColor(pct), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(window == nil ? "–" : "\(pct)%")
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(JcTheme.text)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window == nil ? "\(label) limit not reported" : "\(label) limit \(pct) percent used")
    }
}

enum AgentStyle {
    static func usageColor(_ pct: Int) -> Color {
        pct < 50 ? JcTheme.success : pct < 80 ? JcTheme.amber : JcTheme.danger
    }
}

// MARK: - Empty, loading, failed

struct AgentsEmptyState: View {
    let startSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(JcTheme.glassFill)
                Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 0.5)
                JcIcon("terminal", size: 30).foregroundStyle(JcTheme.accent)
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 4)
            VStack(spacing: 8) {
                Text("No agent sessions yet")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text("Start Claude Code, Codex or another coding agent on your Mac, or tap + to start one on the server. It shows up here live, with its approvals and questions.")
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .frame(maxWidth: 320)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing showing up?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text(Self.hint)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .lineSpacing(2)
            }
            .padding(14)
            .frame(maxWidth: 340, alignment: .leading)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
            Button("Start a session", action: startSession)
                .buttonStyle(.jcGlass(tint: JcTheme.accent))
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
    }

    private static var hint: AttributedString {
        var text = AttributedString("Turn on agent tracking in Jarvis on your Mac, or run ")
        var command = AttributedString("jc-client hooks install")
        command.font = .system(size: 12.5, design: .monospaced)
        command.foregroundColor = JcTheme.text
        text += command
        text += AttributedString(" there.")
        return text
    }
}

/// Placeholder rows while the first list loads.
struct AgentsSkeletonList: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSectionHeader(title: " ")
            ForEach(0..<4, id: \.self) { i in
                HStack(alignment: .top, spacing: 14) {
                    Circle().fill(JcTheme.glassFill).frame(width: 14, height: 14).padding(4)
                    VStack(alignment: .leading, spacing: 8) {
                        bar(width: [230, 180, 250, 160][i], height: 14)
                        bar(width: [150, 120, 170, 110][i], height: 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
        }
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading sessions")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(JcTheme.glassFill)
            .frame(width: width, height: height)
    }
}

struct AgentsErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(JcTheme.glassFill)
                JcIcon("wifi.exclamationmark", size: 26).foregroundStyle(JcTheme.muted)
            }
            .frame(width: 72, height: 72)
            Text("Couldn’t load your agents")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Try again", action: retry)
                .buttonStyle(.jcGlass(tint: JcTheme.accent))
                .padding(.top, 4)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }
}
