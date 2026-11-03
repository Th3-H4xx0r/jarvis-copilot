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
/// MacBook power card, the Mac-asleep card when a Mac left sessions behind,
/// what needs you (Mac password prompts, then a flat list across projects and
/// machines), then every other session in
/// collapsible project groups, and last the runs Jarvis does in the background
/// for an integration (collapsed until opened). Approvals and questions are
/// answered inside each session; "+" starts a new one.
struct AgentsPage: View {
    var store: AgentsStore = .shared
    @Environment(AppRouter.self) private var router
    @State private var path: [AgentsRoute] = []
    @State private var showRecap = false
    @State private var showLaunch = false
    /// The Mac password request the sheet shows, one at a time.
    @State private var passwordSheet: MacPasswordRequest?
    /// Requests he swiped away: they wait under Needs you instead of coming back.
    @State private var snoozedPasswords: Set<String> = []
    @State private var onScreen = false
    @AppStorage(AgentsListPrefs.collapsedKey) private var collapsedRaw = ""
    @AppStorage(AgentsListPrefs.expandedIntegrationsKey) private var expandedIntegrationsRaw = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                JcPageColumn {
                    if store.usage != nil || store.codexUsage != nil {
                        JcSectionLabel("Plan usage", first: true)
                        AgentUsageStrip(claude: store.usage, codex: store.codexUsage)
                    }
                    if !store.macs.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(store.macs) { mac in AgentsMacPowerCard(mac: mac, store: store) }
                        }
                        .padding(.top, store.usage != nil || store.codexUsage != nil ? 12 : 8)
                    }
                    if let card = store.card {
                        AgentsSleepCard(card: card, store: store)
                            .padding(.top, store.usage != nil || store.codexUsage != nil || !store.macs.isEmpty ? 12 : 8)
                    }
                    content
                }
            }
            .refreshable { await store.refresh() }
            .loadErrorBanner(store.loadError, hasContent: !store.isEmpty)
            .jcPageChrome("Agents") {
                JcPageButton("plus", label: "New session") { showLaunch = true }
                menu
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
        .onTabVisibilityChange(.agents) {
            store.setVisible($0)
            onScreen = $0
            syncPasswordSheet()
        }
        .onChange(of: "\(store.openRequest ?? "")|\(store.loaded)", initial: true) { _, _ in
            // A push tap can name its session before the first list is in;
            // wait for it so the tracker key resolves to its conversation.
            guard store.openRequest != nil, store.loaded, let key = store.consumeOpen() else { return }
            path = [.session(store.resolveCkey(key))]
        }
        .onChange(of: store.passwordsRequested, initial: true) { _, _ in
            // A Mac password push: back to the list, and its sheet up again
            // even if he swiped an earlier one away.
            if store.consumePasswords() {
                path = []
                snoozedPasswords = []
                syncPasswordSheet()
            }
        }
        .onChange(of: store.passwordRequests.map(\.id), initial: true) { _, _ in syncPasswordSheet() }
        .onChange(of: showRecap || showLaunch) { _, _ in syncPasswordSheet() }
        .onChange(of: store.recapRequested, initial: true) { _, _ in
            if store.consumeRecap() { showRecap = true }
        }
        .sheet(isPresented: $showRecap) {
            AgentsRecapView(api: store.api)
        }
        .sheet(isPresented: $showLaunch) {
            AgentLaunchSheet(store: store)
        }
        .sheet(item: passwordSheetBinding, onDismiss: syncPasswordSheet) { request in
            MacPasswordSheet(request: request,
                             macName: AgentsMacPowerCopy.macName(request.deviceId, in: store.macs),
                             answer: { await store.answerMacPassword(request, allow: $0) },
                             expired: { if passwordSheet?.id == request.id { passwordSheet = nil } })
        }
    }

    // MARK: Mac password sheet

    /// The sheet's binding: a swipe-down puts the request aside (it stays under
    /// Needs you); the page's own closes (answered, ran out) don't.
    private var passwordSheetBinding: Binding<MacPasswordRequest?> {
        Binding(get: { passwordSheet }, set: { next in
            if next == nil, let shown = passwordSheet,
               store.passwordRequests.contains(where: { $0.id == shown.id }) {
                snoozedPasswords.insert(shown.id)
            }
            passwordSheet = next
        })
    }

    /// Closes the sheet once its request is answered or gone, and puts up the
    /// next waiting one while the Agents tab is on screen and no other sheet is.
    private func syncPasswordSheet() {
        let requests = store.passwordRequests
        if let shown = passwordSheet {
            if MacPasswordQueue.isDone(shown, in: requests) { passwordSheet = nil }
            return
        }
        snoozedPasswords.formIntersection(requests.map(\.id))
        guard onScreen, !showRecap, !showLaunch else { return }
        passwordSheet = MacPasswordQueue.next(requests, snoozed: snoozedPasswords)
    }

    private func openPassword(_ request: MacPasswordRequest) {
        snoozedPasswords.remove(request.id)
        if passwordSheet == nil { passwordSheet = request }
    }

    // MARK: content

    /// The first section on the page sits closer to the title.
    private var contentFirst: Bool {
        store.usage == nil && store.codexUsage == nil && store.macs.isEmpty && store.card == nil
    }

    @ViewBuilder private var content: some View {
        let needs = store.needsYou
        let orphans = store.orphanRequests
        let passwords = store.passwordRequests
        let projects = store.projects
        let integrations = store.integrations
        if !store.loaded {
            AgentsSkeletonList(first: contentFirst)
        } else if needs.isEmpty && orphans.isEmpty && passwords.isEmpty && projects.isEmpty && integrations.isEmpty {
            if let error = store.loadError {
                AgentsErrorState(message: error) { Task { await store.refresh() } }
            } else if store.card == nil {
                AgentsEmptyState { showLaunch = true }
            }
        } else {
            let nothingWaits = needs.isEmpty && orphans.isEmpty && passwords.isEmpty
            if !nothingWaits {
                JcSectionLabel("Needs you", first: contentFirst) {
                    if store.waitingCount > 0 { Text("\(store.waitingCount)").monospacedDigit() }
                }
                VStack(spacing: 10) {
                    if !passwords.isEmpty {
                        JcCard(padding: 0) {
                            ForEach(Array(passwords.enumerated()), id: \.element.id) { index, request in
                                AgentsMacPasswordRow(request: request,
                                                     macName: AgentsMacPowerCopy.macName(request.deviceId, in: store.macs),
                                                     last: index == passwords.count - 1) {
                                    openPassword(request)
                                }
                            }
                        }
                    }
                    ForEach(orphans) { request in
                        AgentRequestCard(request: request, store: store, inset: 0)
                    }
                    if !needs.isEmpty {
                        JcCard(padding: 0) { rows(needs, showsProject: true) }
                    }
                }
            }
            if !projects.isEmpty {
                JcSectionLabel("Projects", first: contentFirst && nothingWaits)
                let collapsed = AgentsListLayout.collapsed(from: collapsedRaw)
                VStack(spacing: 10) {
                    ForEach(projects) { group in
                        let open = AgentsListLayout.isExpanded(group, collapsed: collapsed, needsYou: needs)
                        JcCard(padding: 0) {
                            AgentsProjectHeader(group: group, open: open,
                                                waiting: AgentsListLayout.hasWaiting(group, needsYou: needs)) {
                                toggle(group, collapsed: collapsed)
                            }
                            if open {
                                JcRowSeparator()
                                rows(group.sessions, showsProject: false)
                            }
                        }
                    }
                }
            }
            if !integrations.isEmpty {
                JcSectionLabel("Integrations",
                               first: contentFirst && nothingWaits && projects.isEmpty)
                let expanded = AgentsListLayout.collapsed(from: expandedIntegrationsRaw)
                VStack(spacing: 10) {
                    ForEach(integrations) { group in
                        let open = AgentsListLayout.isExpanded(group, expanded: expanded)
                        JcCard(padding: 0) {
                            AgentsIntegrationHeader(group: group, open: open,
                                                    waiting: AgentsListLayout.hasWaiting(group)) {
                                toggle(group, expanded: expanded)
                            }
                            if open {
                                JcRowSeparator()
                                rows(group.sessions, showsProject: false)
                            }
                        }
                    }
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
            if index < convs.count - 1 { JcRowSeparator(inset: 56) }
        }
    }

    /// Remembers how a group was left. A group with something waiting in it
    /// stays open regardless, and goes back to this once nothing waits.
    private func toggle(_ group: AgentProjectGroup, collapsed: Set<String>) {
        var next = collapsed
        if next.contains(group.id) { next.remove(group.id) } else { next.insert(group.id) }
        withAnimation(.snappy(duration: 0.25)) { collapsedRaw = AgentsListLayout.encode(next) }
    }

    /// An integration group starts shut; this remembers the ones he opened.
    private func toggle(_ group: AgentIntegrationGroup, expanded: Set<String>) {
        var next = expanded
        if next.contains(group.id) { next.remove(group.id) } else { next.insert(group.id) }
        withAnimation(.snappy(duration: 0.25)) { expandedIntegrationsRaw = AgentsListLayout.encode(next) }
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
        HStack(alignment: .top, spacing: 12) {
            AgentStatusMark(status: status)
                .frame(width: JcUnified.iconSquare, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(conv.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(conv.status == .ended ? JcTheme.text.opacity(0.7) : JcTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(AgentsPresentation.time(conv.lastEventAt))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(JcTheme.muted)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                if let detail = AgentsListLayout.detail(conv, request: request) {
                    Text(detail.text)
                        .font(.system(size: 12, weight: detail.tone == .waiting ? .medium : .regular))
                        .foregroundStyle(Self.color(detail.tone))
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
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

/// The quiet status mark: a spinner while it works, a check when it finished,
/// an amber dot while it waits on you, a green dot while it's open and idle.
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
                // Open on the Mac or the server, waiting for you: a green dot.
                Circle().fill(status.color).frame(width: size * 0.5, height: size * 0.5)
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
        JcCard(padding: 0) {
            if let claude { row("Claude", claude) }
            if claude != nil && codex != nil { JcRowSeparator() }
            if let codex { row("Codex", codex) }
        }
    }

    private func row(_ name: String, _ usage: AgentPlanUsage) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                Text(Self.resetLine(usage))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentPlanRings(usage: usage)
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
    }

    /// "5-hour limit resets 3:40 PM", or the week's when that's all there is.
    static func resetLine(_ u: AgentPlanUsage, now: Date = Date()) -> String {
        if let r = u.fiveHour?.resetsAt, r > now {
            return "5-hour limit resets \(r.formatted(date: .omitted, time: .shortened))"
        }
        if let r = u.sevenDay?.resetsAt, r > now {
            return "Weekly limit resets \(r.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
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
        VStack(spacing: 22) {
            JcEmptyState(symbol: "terminal", title: "No agent sessions yet",
                         subtitle: "Start Claude Code, Codex or another agent on your Mac, or tap + to start one on the server")
            JcSmallAction("Start a session", symbol: "plus", action: startSession)
            VStack(alignment: .leading, spacing: 0) {
                JcSectionLabel("Nothing showing up?", first: true)
                JcCard {
                    Text(Self.hint)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .lineSpacing(2)
                }
            }
        }
        .padding(.top, 56)
        .frame(maxWidth: .infinity)
    }

    private static var hint: AttributedString {
        var text = AttributedString("Turn on agent tracking in Jarvis on your Mac, or run ")
        var command = AttributedString("jc-client hooks install")
        command.font = .system(size: 12.5, design: .monospaced)
        command.foregroundColor = JcTheme.text
        text += command
        text += AttributedString(" there")
        return text
    }
}

/// Placeholder rows while the first list loads.
struct AgentsSkeletonList: View {
    var first = true
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel(" ", first: first)
            JcCard(padding: 0) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(JcTheme.glassFill).frame(width: 14, height: 14)
                            .frame(width: JcUnified.iconSquare, height: 20)
                        VStack(alignment: .leading, spacing: 8) {
                            bar(width: [210, 160, 230, 140][i], height: 13)
                            bar(width: [140, 110, 160, 100][i], height: 10)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, JcUnified.cardPadding)
                    .padding(.vertical, 14)
                    if i < 3 { JcRowSeparator(inset: 56) }
                }
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
        VStack(spacing: 18) {
            JcEmptyState(symbol: "wifi.exclamationmark", title: "Couldn’t load your agents", subtitle: message)
            JcSmallAction("Try again", symbol: "arrow.clockwise", action: retry)
        }
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
    }
}
