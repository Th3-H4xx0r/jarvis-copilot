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
    /// The panel's coordinate space: where the orb's flight is measured and drawn.
    static let space = "jc.island"

    @MainActor
    static func expandedHeight(model: AppModel, tab: IslandTab = .agents, topInset: CGFloat = 40,
                               measured: IslandMeasure? = nil, voiceMini: Bool = false) -> CGFloat {
        if tab == .voice && voiceMini { return IslandLayout.voiceMiniHeight(topInset: topInset) }
        if tab == .music { return IslandLayout.musicHeight(topInset: topInset) }
        if tab == .voice { return IslandLayout.voiceHeight(topInset: topInset) }
        if tab != .agents { return tab.height }
        if let m = measured { return IslandLayout.agentsHeight(topInset: topInset, top: m.top, list: m.list) }
        let pending: IslandLayout.Pending? = model.pending.first.map { $0.isQuestion ? .question : .approval }
        return IslandLayout.agentsHeight(topInset: topInset, sessions: model.sessions.count + model.jobs.count,
                                         pending: pending, flash: model.flash != nil)
    }

    /// One spring for the island's shape: a quick but fluid open and close (not a
    /// snap, not a drift), and the same glide when the open island changes height.
    static let morph = Animation.spring(response: 0.36, dampingFraction: 0.84)

    var body: some View {
        let size = shapeSize
        let radius: CGFloat = ui.state == .expanded ? 24 : 12
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
        VStack(spacing: 0) {
            // One black shape that grows from the pill into the open island and
            // back — the content fades in just after it opens, and out first
            // when it closes, like the iPhone's Dynamic Island.
            ZStack(alignment: .top) {
                switch ui.state {
                case .hidden:
                    Color.clear
                case .compact:
                    compact
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                case .expanded:
                    ExpandedIsland(model: model, ui: ui, controller: controller)
                        .frame(width: ui.expandedWidth)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.07)),
                                                removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(ui.state == .expanded ? 0.45 : 0), radius: 14, y: 6)
            .animation(Self.morph, value: size)
            Spacer(minLength: 0)
        }
        .frame(width: IslandController.panelSize.width, height: IslandController.panelSize.height, alignment: .top)
        .coordinateSpace(.named(Self.space))
        // The orb in flight, over everything (the shape clips; it mustn't).
        // Always here, out of sight between flights: a view added in the same
        // update that starts its spring shows at the spring's end — the orb
        // would jump instead of fly. Still (idle mood) while hidden.
        .overlay(alignment: .topLeading) {
            if let ear = ui.orbEar {
                let flight = ui.orbFlight
                FlyingOrb(ear: ear,
                          home: flight?.from ?? ui.orbHomes[flight?.home ?? OrbHome.of(ui.tab)] ?? ear,
                          progress: ui.orbProgress,
                          mood: flight != nil && model.connected ? model.mood : .idle)
                    .opacity(flight == nil ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The shape's size in each state: the notch, the pill with its ears, or
    /// the open island at its tab's height.
    private var shapeSize: CGSize {
        switch ui.state {
        case .hidden:
            return CGSize(width: ui.geometry.width, height: ui.geometry.height)
        case .compact:
            return CGSize(width: ui.compactWidth, height: ui.geometry.height)
        case .expanded:
            return CGSize(width: ui.expandedWidth,
                          height: Self.expandedHeight(model: model, tab: ui.tab, topInset: ui.geometry.height + 8,
                                                      measured: ui.agentsMeasure, voiceMini: ui.voiceMini))
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { ui.orbEar = $0 }
            .opacity(ui.hidesEar ? 0 : 1)
            .frame(width: IslandController.earWidth)
            .contentShape(Rectangle())
            .onTapGesture { controller.openVoice() }     // the orb: talk to Jarvis
            .help("Talk to Jarvis")
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

/// The orb in flight between the notch and the open island: it drops out of
/// the notch, glides into place growing to home's size (a soft accent light
/// with it mid-flight, none at either end), swells a touch as it lands, and
/// the orb in its place takes over. Animatable on `progress`, so one spring
/// drives the whole path.
struct FlyingOrb: View, Animatable {
    var ear: CGRect
    var home: CGRect
    var progress: CGFloat
    var mood: OrbMood

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = OrbPath.at(progress, ear: ear, home: home)
        // Drawn once at its biggest and scaled, so the shader's surface never
        // changes size mid-flight (that would redraw it squashed).
        let big = max(ear.width, home.width) * 1.1
        ZStack {
            Circle()
                .fill(JcAccent.color.opacity(0.3 * OrbPath.glow(progress)))
                .frame(width: p.side * 1.8, height: p.side * 1.8)
                .blur(radius: p.side * 0.4)
            OrbView(mood: mood, skin: OrbSkin.current, size: big)
                .scaleEffect(p.side / big)
        }
        .position(p.center)
    }
}

extension View {
    /// The open island's orb for `home`: measured for the flight, and out of
    /// sight while the flying orb travels to (or from) it.
    func orbHome(_ home: OrbHome, ui: IslandUI) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandRootView.space)) } action: {
            ui.reportOrbHome(home, $0)
        }
        .opacity(ui.hidesOrb(home) ? 0 : 1)
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
    @State private var scroll: ScrollGeometry?

    var body: some View {
        if ui.tab == .voice && ui.voiceMini {
            mini
        } else {
            full
        }
    }

    /// Push to talk: the small voice island — the orb and your words, then
    /// Jarvis's answer — in a band under the notch. A click opens the stage.
    private var mini: some View {
        VoicePane(ui: ui, make: controller.voiceMiniPanel, height: IslandLayout.voiceMiniBand - 10)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { controller.expandVoice() }
                    .help("Open the voice view")
            }
            .padding(.horizontal, 14)
            .padding(.top, ui.geometry.height + 8)
            .padding(.bottom, 10)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabs
            switch ui.tab {
            case .agents: agents
            case .chat: ChatPane(ui: ui)
            case .services: ServicesPane(model: model)
            case .music: MusicPane()
            case .mail: MailPane(ui: ui)
            case .voice: VoicePane(ui: ui, make: controller.voicePanel).id("voice-stage")
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
            ForEach(IslandTab.tabBar) { t in
                Button { withAnimation(.easeOut(duration: 0.18)) { ui.tab = t } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 11, weight: .semibold))
                        if ui.tab == t { Text(t.title).font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    // Bare glyphs; only the selected tab sits in a capsule.
                    .background(Capsule().fill(ui.tab == t ? Color.white.opacity(0.10) : .clear))
                    .foregroundStyle(ui.tab == t ? Color.white : .white.opacity(0.55))
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
            Button { withAnimation(.easeOut(duration: 0.18)) { ui.tab = ui.tab == .voice ? .agents : .voice } } label: {
                OrbView(mood: ui.tab == .voice ? .listening : .idle, skin: OrbSkin.current, size: 18)
                    .orbHome(.row, ui: ui)
                    .padding(4)
                    .background(Circle().fill(ui.tab == .voice ? JcAccent.color.opacity(0.22) : .white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Talk to Jarvis")
            Button { controller.close() } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
        .frame(height: IslandLayout.tabsHeight)
    }

    @ViewBuilder private var agents: some View {
        VStack(alignment: .leading, spacing: 10) {
            agentsTop
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ui.agentsTop = $0 }
            agentList
        }
    }

    /// Everything above the list: the header, the limits when open, and what's
    /// waiting on you.
    @ViewBuilder private var agentsTop: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if ui.showLimits && (model.usage != nil || model.codexUsage != nil) {
                LimitsCard(claude: model.usage, codex: model.codexUsage)
                    .transition(.opacity)
            }
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
        }
    }

    /// The sessions. An opened one grows the island; past the panel's height
    /// the list scrolls, with a slim bar on the right.
    private var agentList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    if model.sessions.isEmpty && model.jobs.isEmpty && model.connected {
                        Text("No agent sessions. Start Claude Code (or Codex, Gemini…) and it shows up here.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // What Jarvis handed to a bigger model, first: it's what you
                    // just asked for.
                    ForEach(model.jobs) { j in
                        JobRow(job: j, selected: model.selectedKey == j.key)
                            .id(j.key)
                            .onTapGesture {
                                model.selectedKey = model.selectedKey == j.key ? nil : j.key
                            }
                        if model.selectedKey == j.key {
                            JobDetail(job: j, model: model)
                        }
                    }
                    ForEach(model.sessions) { s in
                        SessionRow(session: s, selected: model.selectedKey == s.key)
                            .id(s.key)
                            .onTapGesture {
                                model.selectedKey = model.selectedKey == s.key ? nil : s.key
                            }
                        if model.selectedKey == s.key {
                            SessionDetail(session: s)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ui.agentsList = $0 }
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, g in scroll = g }
            .overlay(alignment: .topTrailing) { SlimScrollBar(geometry: scroll).offset(x: 10) }
            .onChange(of: model.selectedKey) { _, key in
                guard let key else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .top) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OrbView(mood: model.mood, skin: OrbSkin.current, size: 22)
                .orbHome(.agents, ui: ui)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agents").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text(summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if model.usage != nil || model.codexUsage != nil {
                // The pills open the limits card: each window's bar, reset and pace.
                Button { withAnimation(IslandRootView.morph) { ui.showLimits.toggle() } } label: {
                    HStack(spacing: 6) {
                        if let u = model.usage {
                            UsagePill(label: "5h", pct: u.fiveHour)
                            UsagePill(label: "wk", pct: u.sevenDay)
                        }
                        if let c = model.codexUsage {
                            UsagePill(label: "Codex", pct: c.fiveHour ?? c.sevenDay)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(ui.showLimits ? "Hide the limits" : "Show the limits")
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

/// Each agent's limits, side by side: its current session and its week, as a
/// bar with when it resets, how much is used and left, and the pace — ahead of
/// the clock (a deficit) or under it (reserved).
private struct LimitsCard: View {
    let claude: MacPlanUsage?
    let codex: MacPlanUsage?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(alignment: .top, spacing: 10) {
                if let claude { AgentLimits(name: "Claude", usage: claude, now: ctx.date) }
                if let codex { AgentLimits(name: "Codex", usage: codex, now: ctx.date) }
            }
        }
    }
}

private struct AgentLimits: View {
    let name: String
    let usage: MacPlanUsage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(name) usage").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if let w = usage.five { LimitRow(title: "Current session", window: w, length: UsagePace.fiveHours, now: now) }
            if let w = usage.week { LimitRow(title: "Weekly · all models", window: w, length: UsagePace.week, now: now) }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private struct LimitRow: View {
    let title: String
    let window: MacPlanUsage.Window
    let length: TimeInterval
    let now: Date

    var body: some View {
        let reset = window.resetsAt <= now
        let used = reset ? 0 : window.used
        let pace = reset ? 0 : UsagePace.pace(used: used, resetsAt: window.resetsAt, length: length, now: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 6)
                Text(reset ? "Reset" : "Resets in \(UsagePace.resetsIn(window.resetsAt, now: now))")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Self.color(used)).frame(width: g.size.width * CGFloat(used) / 100)
                }
            }
            .frame(height: 5)
            (Text("\(used)% used · \(100 - used)% left").foregroundColor(.white.opacity(0.75))
             + Text(abs(pace) < 0.5 ? "" : pace > 0 ? " · \(Self.one(pace))% deficit" : " · \(Self.one(-pace))% reserved")
                .foregroundColor(pace > 0 ? islandAmber : .white.opacity(0.45)))
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
    }

    static func color(_ used: Int) -> Color {
        used >= 90 ? Color(red: 0.97, green: 0.30, blue: 0.30) : used >= 75 ? islandAmber : JcAccent.color
    }

    static func one(_ v: Double) -> String { String(format: "%.1f", v) }
}

/// A thin scroll bar on the right, there only while the list is taller than
/// the island.
private struct SlimScrollBar: View {
    let geometry: ScrollGeometry?

    var body: some View {
        if let g = geometry, let thumb = IslandLayout.scrollThumb(content: g.contentSize.height,
                                                                 visible: g.containerSize.height,
                                                                 offset: g.contentOffset.y) {
            Capsule().fill(.white.opacity(0.35))
                .frame(width: 4, height: thumb.length)
                .offset(y: thumb.start)
                .allowsHitTesting(false)
        }
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

/// A job a harness handed to a bigger model: who has it, how it stands, and
/// what it's doing now (or the first line of its answer once it's done).
private struct JobRow: View {
    let job: MacJob
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(stateColor(job.state)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.agentName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Hand-off · \(job.stateLabel)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    if job.running {
                        // The clock ticks while it works.
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(job.elapsed(now: ctx.date))
                        }
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                if !job.task.isEmpty {
                    Text(job.task).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Text(job.line).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(job.state == .error ? Color.red.opacity(0.85) : .white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.10 : 0.05)))
        .contentShape(Rectangle())
    }
}

/// An opened job: what was asked and where from, its recent steps, and its
/// whole answer (selectable, scrolling) with Read aloud and Copy.
private struct JobDetail: View {
    let job: MacJob
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([job.origin, job.modelName, "\(job.steps) step\(job.steps == 1 ? "" : "s")",
                  job.running ? "" : job.elapsed()].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            if !job.task.isEmpty {
                Text(job.task).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
            }
            ForEach(Array(job.trail.suffix(5).enumerated()), id: \.offset) { _, step in
                Text("› \(step.text)\(step.detail.isEmpty ? "" : " — \(step.detail)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            if !job.result.isEmpty {
                ScrollView {
                    Text(job.result)
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 170)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                HStack {
                    Button("Read aloud") { model.readAloud(job) }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.result, forType: .string)
                    }
                    Spacer()
                }
                .buttonStyle(IslandButtonStyle(tint: .white.opacity(0.8)))
            }
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
