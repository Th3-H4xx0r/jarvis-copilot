import SwiftUI

/// One agent session as a conversation, laid out like the Claude app's Code
/// sessions: your prompts on the right, the agent's words in plain Markdown,
/// each tool call a quiet line, each changed file a card, a live row while it
/// works, and whatever it waits on inline at the bottom. A slim top bar holds
/// the title, a status pill and a ••• menu; the composer is fixed underneath.
///
/// The full Claude Code transcript when the session has one, else the agent's
/// own last turn (`AgentTranscriptChoice`). Reloads when the session's hooks
/// report something new — the store hears the `agents` push — so nothing polls.
struct AgentSessionScreen: View {
    let key: String
    let store: AgentsStore
    var navigate: (AgentsRoute) -> Void = { _ in }
    var showRecap: () -> Void = {}

    @Environment(AppRouter.self) private var router
    @State private var model: AgentSessionModel
    @State private var fullDiff: AgentFileEdit?
    @State private var copied = false

    init(key: String, store: AgentsStore,
         navigate: @escaping (AgentsRoute) -> Void = { _ in },
         showRecap: @escaping () -> Void = {}) {
        self.key = key
        self.store = store
        self.navigate = navigate
        self.showRecap = showRecap
        _model = State(initialValue: AgentSessionModel(key: key, agents: store.api))
    }

    private var live: AgentSessionItem? { store.session(key: key) ?? model.detail?.item }
    private var request: AgentRequest? { store.requests.first { $0.key == key } }
    private var state: AgentState { live?.state ?? .idle }
    private var status: AgentRowStatus { AgentRowStatus.of(state, waiting: request != nil) }
    private var working: Bool { status == .working }
    private var codingId: String? { live?.codingSessionId }
    private var agentName: String { live?.agentName ?? "the agent" }

    var body: some View {
        let choice = model.choice(codingSessionId: codingId)
        let items = model.items(codingSessionId: codingId, working: working)
        let outgoing = store.outgoing(for: key)
        let prompts = AgentConversation.prompts(items)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let s = live { AgentConversationHeader(session: s, lastTurnOnly: choice == .lastTurn) }
                    switch choice {
                    case .loading:
                        AgentConversationSkeleton()
                    case .empty:
                        if outgoing.isEmpty && request == nil && !working {
                            AgentConversationEmpty(agentName: agentName, error: model.error)
                        }
                    case .transcript, .lastTurn:
                        if choice == .transcript && model.transcript.hasOlder {
                            // Reaching the top loads the page above, keeping your place.
                            AgentEarlierRow(loading: model.loadingOlder)
                                .onAppear {
                                    let anchor = items.first?.id
                                    Task {
                                        await model.loadOlder()
                                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                    }
                                }
                        }
                        ForEach(items) { item in
                            AgentConversationRow(item: item, cwd: live?.cwd ?? "") { fullDiff = $0 }
                        }
                    }
                    ForEach(outgoing) { o in
                        AgentOutgoingBubble(
                            outgoing: o,
                            retry: { Task { await store.retry(o.id, key: key) } },
                            dismiss: { withAnimation { store.dismissOutgoing(o.id, key: key) } },
                            openSettings: { navigate(.settings) })
                    }
                    if working && request == nil && !AgentConversation.endsInRunningTool(items) {
                        AgentWorkingRow(text: AgentsPresentation.working(
                            statusLine: choice == .transcript ? model.transcript.statusLine : nil,
                            step: live?.step ?? "", state: state))
                    }
                    if let request {
                        AgentRequestCard(request: request, store: store, showsProject: false)
                            .padding(.top, 14)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.bottom, 12)
            }
            .modifier(AgentOpensAtTheEnd())
            .environment(\.agentLoadDetails, AgentLoadDetails { i in Task { await model.loadDetails(i) } })
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await reload() }
            .onChange(of: "\(items.last?.id ?? "")|\(outgoing.count)|\(request == nil ? 0 : 1)") { old, _ in
                // Follows what arrives at the END (an older page coming in on
                // top doesn't move you). The first page jumps; the rest slides in.
                if old.hasPrefix("|") {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AgentComposer(placeholder: "Reply to \(agentName)…", working: working) { text in
                Task { await store.send(text, to: key, prompts: prompts) }
            }
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { topBar }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .overlay(alignment: .top) {
            if copied {
                Text("Session id copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .jcLiquidGlass(in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await reload() }
        .onChange(of: store.session(key: key)?.lastEventAt) { _, _ in
            Task { await reload() }
        }
        .onChange(of: prompts) { _, now in store.reconcileOutgoing(key: key, prompts: now) }
        .sheet(item: $fullDiff) { edit in
            NavigationStack {
                AgentDiffView(edit: edit)
                    .navigationTitle(edit.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { fullDiff = nil } }
                    }
            }
        }
    }

    private static let bottom = "agent-bottom"


    private func reload() async {
        await model.load(codingSessionId: codingId)
    }

    // MARK: top bar

    private var topBar: some View {
        VStack(spacing: 3) {
            Text(live.map(AgentsPresentation.title) ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            AgentStatusPill(status: status, label: AgentRowStatus.label(state, request: request))
        }
        .frame(maxWidth: 250)
        .accessibilityElement(children: .combine)
    }

    private var menu: some View {
        Menu {
            Button { openTerminal() } label: { Label("Open terminal", jcIcon: "terminal") }
                .disabled(codingId == nil)
            Button { copySessionId() } label: { Label("Copy session id", jcIcon: "doc.on.doc") }
                .disabled((live?.sessionId ?? "").isEmpty)
            Divider()
            Button { navigate(.history) } label: { Label("History", jcIcon: "clock.arrow.circlepath") }
            Button { showRecap() } label: { Label("This week’s recap", jcIcon: "chart.line.uptrend.xyaxis") }
        } label: {
            JcIcon("ellipsis", size: 17)
                .foregroundStyle(JcTheme.text)
        }
        .accessibilityLabel("More")
    }

    /// The session's own terminal — the Mac's tmux pane, live — in Coding.
    private func openTerminal() {
        guard let codingId else { return }
        AppDeepLinkRouter(router: router).open(.coding(session: codingId))
    }

    private func copySessionId() {
        guard let id = live?.sessionId, !id.isEmpty else { return }
        UIPasteboard.general.string = id
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.3)) { copied = false }
        }
    }
}

/// The top of a long chat while its earlier pages load.
private struct AgentEarlierRow: View {
    let loading: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Earlier messages").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .opacity(loading ? 1 : 0.7)
    }
}

/// Opens at the newest message while a short conversation still starts at
/// the top (a bottom anchor alone would leave a gap above it).
private struct AgentOpensAtTheEnd: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}

extension AgentFileEdit: Identifiable {
    var id: String { path }
}

/// The status in the top bar: a soft capsule, the colour in its dot and words.
struct AgentStatusPill: View {
    let status: AgentRowStatus
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .working: AgentSpinner(size: 8, color: status.color)
            default: Circle().fill(status.color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(status.color.opacity(0.14), in: Capsule())
    }
}

/// The quiet lines above the conversation: where it runs, and since when.
struct AgentConversationHeader: View {
    let session: AgentSessionItem
    var lastTurnOnly = false

    var body: some View {
        VStack(spacing: 4) {
            Text(AgentsPresentation.meta(session))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
            Text(secondLine)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
            if lastTurnOnly {
                Text("Showing the last turn")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(JcTheme.glassFill, in: Capsule())
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var secondLine: String {
        let started = "Started \(session.startedAt.formatted(date: .omitted, time: .shortened))"
        let path = AgentsPresentation.shortPath(session.cwd)
        return path.isEmpty ? started : "\(path) · \(started)"
    }
}

/// While the first page of the conversation loads.
struct AgentConversationSkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(JcTheme.glassFill)
                    .frame(width: 210, height: 44)
            }
            ForEach([260, 220, 240], id: \.self) { w in
                HStack(spacing: 10) {
                    Circle().fill(JcTheme.glassFill).frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(JcTheme.glassFill)
                        .frame(width: CGFloat(w) * 0.6, height: 12)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach([300, 280, 180], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(JcTheme.glassFill)
                        .frame(width: CGFloat(w), height: 12)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading the conversation")
    }
}

/// Nothing said yet in this session.
struct AgentConversationEmpty: View {
    let agentName: String
    var error: String?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(JcTheme.glassFill)
                JcIcon(error == nil ? "bubble.left" : "exclamationmark.circle", size: 24)
                    .foregroundStyle(error == nil ? JcTheme.accent : JcTheme.muted)
            }
            .frame(width: 64, height: 64)
            Text(error == nil ? "No conversation yet" : "Couldn’t load this session")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(error ?? "When \(agentName) starts a turn, it shows up here. You can also start one below.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}
