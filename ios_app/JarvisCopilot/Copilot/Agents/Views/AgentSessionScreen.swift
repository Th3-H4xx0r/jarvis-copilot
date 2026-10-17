import SwiftUI

/// One conversation, laid out like the Claude app's Code sessions: your
/// prompts on the right, the agent's words in plain Markdown, each tool call a
/// quiet line, each changed file a card, a live row while it works, and
/// whatever it waits on inline at the bottom. The chat is how a session is
/// driven from the phone; the ••• menu holds the rest — its terminal (for a
/// background session), Continue on server or on the Mac, Resume, Stop and the
/// project's settings.
///
/// The full transcript from the server's copy, else the agent's own last turn
/// (`AgentTranscriptChoice`). Reloads when the `agents_list` push says
/// something new happened in it, so nothing polls.
struct AgentSessionScreen: View {
    let ckey: String
    let store: AgentsStore
    var navigate: (AgentsRoute) -> Void = { _ in }
    var showRecap: () -> Void = {}

    @State private var model: AgentSessionModel
    @State private var fullDiff: AgentFileEdit?
    @State private var copied = false
    @State private var showTerminal = false
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var askResume = false
    @State private var confirmOffline = false

    init(ckey: String, store: AgentsStore,
         navigate: @escaping (AgentsRoute) -> Void = { _ in },
         showRecap: @escaping () -> Void = {}) {
        self.ckey = ckey
        self.store = store
        self.navigate = navigate
        self.showRecap = showRecap
        _model = State(initialValue: AgentSessionModel(ckey: ckey, agents: store.api))
    }

    private var conv: AgentConv? { store.conv(ckey) }
    private var request: AgentRequest? { conv.flatMap(store.request(for:)) }
    private var state: AgentState { conv?.state ?? .idle }
    private var status: AgentRowStatus {
        conv.map { AgentsListLayout.status($0, request: request) } ?? .idle
    }
    private var working: Bool { status == .working }
    private var agentName: String { conv?.agentName ?? "the agent" }
    private var busy: Bool { store.busy.contains(ckey) }

    var body: some View {
        let choice = model.choice()
        let items = model.items(working: working)
        let outgoing = store.outgoing(for: ckey)
        let prompts = AgentConversation.prompts(items)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let c = conv { AgentConversationHeader(conv: c, lastTurnOnly: choice == .lastTurn) }
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
                            AgentConversationRow(item: item, cwd: conv?.cwd ?? "") { fullDiff = $0 }
                        }
                    }
                    ForEach(outgoing) { o in
                        AgentOutgoingBubble(
                            outgoing: o,
                            retry: { Task { await store.retry(o.id, ckey: ckey) } },
                            dismiss: { withAnimation { store.dismissOutgoing(o.id, ckey: ckey) } },
                            continueOnServer: conv?.canContinueServer == true ? { continueOnServer() } : nil)
                    }
                    if working && request == nil && !AgentConversation.endsInRunningTool(items) {
                        AgentWorkingRow(text: AgentsPresentation.working(
                            statusLine: choice == .transcript ? model.transcript.statusLine : nil,
                            step: conv?.step ?? "", state: state))
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
            if let c = conv, let reason = AgentsListLayout.cantSendReason(c) {
                AgentCantSendBar(reason: reason, conv: c, busy: busy,
                                 continueOnServer: { continueOnServer() },
                                 resume: { askResume = true })
            } else {
                AgentComposer(placeholder: "Reply to \(agentName)…", working: working) { text in
                    Task { await store.send(text, to: ckey, prompts: prompts) }
                }
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
                notice("Session id copied")
            } else if let error = store.actionError {
                notice(error, tone: JcTheme.danger)
                    .onTapGesture { store.clearActionError() }
            }
        }
        .task { await reload() }
        .onChange(of: AgentsListLayout.transcriptReloadKey(conv, listTs: store.list?.ts ?? 0)) { _, _ in
            Task { await reload() }
        }
        .onChange(of: prompts) { _, now in store.reconcileOutgoing(ckey: ckey, prompts: now) }
        .sheet(item: $fullDiff) { edit in
            NavigationStack {
                AgentDiffView(edit: edit)
                    .navigationTitle(edit.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { fullDiff = nil }.foregroundStyle(JcTheme.accent)
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            AgentTerminalView(ckey: ckey, title: conv?.title ?? "Terminal", api: store.api)
        }
        .sheet(isPresented: $showSettings) {
            if let pid = conv?.projectId {
                AgentProjectSettingsSheet(projectId: pid, api: store.api)
            }
        }
        .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { Task { await store.stop(ckey) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(conv?.onServer == true
                 ? "It ends on the server. You can resume it later."
                 : "Jarvis interrupts \(agentName) on \(conv?.ownerName ?? "the Mac"), then ends it if it doesn’t stop.")
        }
        .confirmationDialog("Resume where?", isPresented: $askResume, titleVisibility: .visible) {
            Button("On the server") { Task { await store.resume(ckey, onServer: true) } }
            Button("On the Mac") { Task { await store.resume(ckey, onServer: false) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Continue on the server?", isPresented: $confirmOffline, titleVisibility: .visible) {
            Button("Continue on server") { Task { await store.continueOnServer([ckey], confirmOffline: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AgentsListLayout.offlineWarning(conv?.ownerName ?? "The Mac", count: 1))
        }
    }

    private static let bottom = "agent-bottom"

    private func reload() async {
        await model.load(key: conv?.key)
    }

    private func notice(_ text: String, tone: Color = JcTheme.text) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tone)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .jcLiquidGlass(in: Capsule())
            .padding(.top, 8)
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// An offline Mac may still run it, so that asks first.
    private func continueOnServer() {
        if conv?.status == .offline {
            confirmOffline = true
            return
        }
        Task {
            if case .needsConfirmation = await store.continueOnServer([ckey]) { confirmOffline = true }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        VStack(spacing: 3) {
            Text(conv?.title ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            AgentStatusPill(status: status,
                            label: conv.map { AgentsListLayout.statusLabel($0, request: request) } ?? "Session")
        }
        .frame(maxWidth: 250)
        .accessibilityElement(children: .combine)
    }

    private var menu: some View {
        Menu {
            if conv?.canTerminal == true {
                Button { showTerminal = true } label: { Label("Terminal", jcIcon: "terminal") }
            }
            if conv?.canContinueServer == true {
                Button { continueOnServer() } label: { Label("Continue on server", jcIcon: "server.rack") }
            }
            if conv?.canContinueMac == true {
                Button { Task { await store.continueOnMac(ckey) } } label: {
                    Label("Continue on \(conv?.movedFromName.isEmpty == false ? conv!.movedFromName : "Mac")",
                          jcIcon: "laptopcomputer")
                }
            }
            if conv?.canResume == true {
                Button { askResume = true } label: { Label("Resume", jcIcon: "play.circle") }
            }
            if conv?.isLive == true {
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", jcIcon: "stop.circle") }
            }
            Divider()
            if conv?.projectId != nil {
                Button { showSettings = true } label: { Label("Project settings", jcIcon: "gearshape") }
            }
            Button { copySessionId() } label: { Label("Copy session id", jcIcon: "doc.on.doc") }
                .disabled((conv?.sessionId ?? "").isEmpty)
            Button { navigate(.history) } label: { Label("History", jcIcon: "clock.arrow.circlepath") }
            Button { showRecap() } label: { Label("This week’s recap", jcIcon: "chart.line.uptrend.xyaxis") }
        } label: {
            Group {
                if busy {
                    AgentSpinner(size: 15)
                } else {
                    JcIcon("ellipsis", size: 17).foregroundStyle(JcTheme.text)
                }
            }
        }
        .disabled(busy)
        .accessibilityLabel("More")
    }

    private func copySessionId() {
        guard let id = conv?.sessionId, !id.isEmpty else { return }
        UIPasteboard.general.string = id
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.3)) { copied = false }
        }
    }
}

/// In place of the message box when the session can't take one: why, and the
/// way on (Continue on server for an asleep Mac, Resume for an ended session).
struct AgentCantSendBar: View {
    let reason: String
    let conv: AgentConv
    var busy = false
    let continueOnServer: () -> Void
    let resume: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                JcIcon(conv.status == .asleep ? "moon.fill" : "info.circle", size: 13)
                    .foregroundStyle(conv.status == .asleep ? AgentRowStatus.paused.color : JcTheme.muted)
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if conv.canContinueServer || conv.canResume {
                HStack(spacing: 10) {
                    if conv.canContinueServer {
                        Button(action: continueOnServer) {
                            if busy { AgentSpinner(size: 12) } else { Text("Continue on server") }
                        }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    }
                    if conv.canResume {
                        Button("Resume", action: resume)
                            .buttonStyle(.jcGlass(tint: JcTheme.text, compact: true))
                    }
                }
                .disabled(busy)
            }
        }
        .padding(14)
        .jcLiquidGlass(in: shape)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [JcTheme.bg.opacity(0), JcTheme.bg.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea())
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

/// The quiet lines above the conversation: where it runs, and where on disk.
struct AgentConversationHeader: View {
    let conv: AgentConv
    var lastTurnOnly = false

    var body: some View {
        VStack(spacing: 4) {
            Text(AgentsPresentation.meta(conv))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
            if !secondLine.isEmpty {
                Text(secondLine)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
        var parts: [String] = []
        let path = AgentsPresentation.shortPath(conv.cwd)
        if !path.isEmpty { parts.append(path) }
        if conv.onServer, !conv.movedFromName.isEmpty { parts.append("moved from \(conv.movedFromName)") }
        return parts.joined(separator: " · ")
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
