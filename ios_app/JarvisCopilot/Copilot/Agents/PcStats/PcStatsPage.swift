import SwiftUI

/// The PC's stats page (Agents → the PC card → View stats): his dashboard reflowed into one
/// column in look B, with the switcher, Live / 1 h / 24 h and Edit up top, and the history
/// (game sessions, energy, marked moments, long-term health) underneath. Live values come
/// every second, and only while the page is on screen.
struct PcStatsPage: View {
    let deviceId: String
    let name: String

    @State private var model: PcStatsModel
    @State private var editing: PcDashboard?
    @State private var naming = false
    @State private var newName = ""
    @State private var actionError: String?
    @Environment(\.scenePhase) private var scenePhase

    init(deviceId: String, name: String, model: PcStatsModel? = nil) {
        self.deviceId = deviceId
        self.name = name
        _model = State(initialValue: model ?? PcStatsModel(deviceId: deviceId, name: name))
    }

    private var isOn: Bool { PowerState.shared.isOn("pc-stats") }

    var body: some View {
        ScrollView { content }
        .background(JcTheme.bg.ignoresSafeArea())
        .refreshable { await model.refresh() }
        .overlay(alignment: .top) { bannerView }
        .jcPageChrome(isOn ? model.name : "PC Stats") {
            if isOn, let board = model.active {
                JcPageButton("slider.horizontal.3", label: "Edit dashboard") { editing = board }
            }
        }
        .task { if isOn { await model.start() } }
        .task(id: scenePhase == .active && isOn) {
            guard scenePhase == .active, isOn else { return }
            await model.pollLive()
        }
        .sheet(item: $editing) { board in
            PcDashboardEditor(model: model, original: board)
        }
        .alert("New dashboard", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { create() }
        } message: {
            Text("Starts empty; add widgets from the library.")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Everything under the title, in the page column (also what the layout tests measure).
    var content: some View {
        JcPageColumn {
            if !isOn {
                offCard
            } else {
                header
                JcSegmentedPicker(PcRange.allCases.map { ($0, $0.title) }, selection: $model.range)
                    .padding(.top, 14)
                dashboard.padding(.top, 14)
                PcStatsHistorySections(model: model)
            }
        }
    }

    // MARK: Header

    /// Under the PC's name (the page title): online / playing / last seen, and the switcher —
    /// side by side when both fit whole, else the switcher goes under the status.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let status = model.liveLoaded
                ? PcStatsCopy.status(online: model.live.online, at: model.live.at, game: model.live.displayGame, now: context.date)
                : "Connecting…"
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    statusLine(status).fixedSize()
                    Spacer(minLength: 8)
                    switcher
                }
                VStack(alignment: .leading, spacing: 10) {
                    statusLine(status)
                    switcher
                }
            }
        }
    }

    /// Playing: the game's Windows icon + "Playing Call of Duty"; else a small dot (white when
    /// online, faint when not) + the status.
    private func statusLine(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if model.live.online, model.live.game != nil {
                PcGameIcon(game: PcGameStore.shared.game(model.live.game), size: 22)
            } else {
                Circle()
                    .fill(model.live.online ? PcLook.accent : PcLook.tertiary)
                    .frame(width: 8, height: 8)
            }
            Text(text).lineLimit(2)
        }
        .font(.system(size: 15))
        .foregroundStyle(PcLook.secondary)
        .accessibilityElement(children: .combine)
    }

    private var switcher: some View {
        Menu {
            Picker("Dashboard", selection: Binding(get: { model.active?.id ?? "" }, set: { model.setActive($0) })) {
                ForEach(model.dashboards) { d in
                    Text(d.name).tag(d.id)
                }
            }
            Divider()
            Button { newName = ""; naming = true } label: { Label("New dashboard", jcIcon: "plus") }
            if let board = model.active {
                Button { editing = board } label: { Label("Edit \(board.name)", jcIcon: "slider.horizontal.3") }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.active?.name ?? "Dashboards")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(JcButton.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PcLook.control, in: Capsule())
        }
        .accessibilityLabel("Dashboard: \(model.active?.name ?? "none")")
        .accessibilityHint("Switch dashboards, make a new one or edit this one")
    }

    // MARK: Dashboard

    @ViewBuilder
    private var dashboard: some View {
        if !model.dashboardsLoaded {
            if let err = model.loadError {
                PcPanel {
                    Text(err).font(.subheadline).foregroundStyle(JcTheme.muted)
                    JcSmallAction("Retry", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                        .padding(.top, 10)
                }
            } else {
                JcLoader("Loading dashboards", size: 24)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            }
        } else if let board = model.active {
            if board.widgets.isEmpty {
                PcPanel {
                    Text("No widgets yet").font(.headline).foregroundStyle(JcTheme.text)
                    Text("Add numbers, charts and bars from the library.")
                        .font(.system(size: 15)).foregroundStyle(PcLook.secondary).padding(.top, 4)
                    JcSmallAction("Add widgets", symbol: "plus") { editing = board }.padding(.top, 12)
                }
            } else {
                PcDashboardColumn(widgets: board.widgets, ctx: model.widgetContext)
                    .animation(.easeOut(duration: 0.25), value: board.widgets.map(\.id))
            }
        } else {
            PcPanel {
                Text("No dashboards").font(.headline).foregroundStyle(JcTheme.text)
                JcSmallAction("New dashboard", symbol: "plus") { newName = ""; naming = true }.padding(.top, 10)
            }
        }
    }

    private var offCard: some View {
        JcCard {
            Label("PC Stats is off", jcIcon: "gauge.with.dots.needle.67percent")
                .font(.headline)
                .foregroundStyle(JcTheme.text)
            Text("Turn it on in Integrations to see your PC's live stats and history.")
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bannerView: some View {
        if let text = model.banner {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(JcTheme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(JcTheme.surfaceAlt, in: Capsule())
                .overlay(Capsule().strokeBorder(JcTheme.border, lineWidth: 1))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { model.banner = nil }
                }
        }
    }

    private func create() {
        let name = newName
        newName = ""
        Task {
            switch await model.createDashboard(name: name) {
            case .saved:
                if let board = model.active { editing = board }
            case .invalid(let errors): actionError = errors.joined(separator: "\n")
            case .failed(let why): actionError = why
            case .conflict: break
            }
        }
    }
}

// MARK: - The one-column dashboard

/// The dashboard in one column: full-width cards, and two small tiles side by side only when
/// both fit at half width (otherwise stacked). Nothing in it is ever wider than the column.
struct PcDashboardColumn: View {
    let widgets: [PcWidget]
    let ctx: PcWidgetContext

    var body: some View {
        VStack(spacing: PcLook.gap) {
            ForEach(PcLayout.rows(PcLayout.reflow(widgets)), id: \.first!.id) { row in
                if row.count == 2 {
                    PcPairLayout(spacing: PcLook.gap) {
                        ForEach(row) { w in PcWidgetView(widget: w, ctx: ctx) }
                    }
                } else {
                    ForEach(row) { w in PcWidgetView(widget: w, ctx: ctx) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The PC card's numbers

/// Under the PC card's header while PC Stats is on: CPU, GPU, the hottest temperature and
/// the whole-PC watts, every 5 s while the card is on screen, and View stats.
struct PcStatsCardSection: View {
    let deviceId: String
    let name: String
    /// The PC is up but its Jarvis app (which sends the stats) isn't.
    var appDown = false
    @State private var model: PcStatsSummaryModel

    init(deviceId: String, name: String, appDown: Bool = false) {
        self.deviceId = deviceId
        self.name = name
        self.appDown = appDown
        _model = State(initialValue: PcStatsSummaryModel(deviceId: deviceId))
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                content(now: context.date)
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 14)
            JcRowSeparator()
            NavigationLink(value: AgentsRoute.pcStats(deviceId: deviceId, name: name)) {
                HStack {
                    Text("View stats")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.accent)
                    Spacer(minLength: 8)
                    JcRowChevron()
                }
                .padding(.horizontal, JcUnified.cardPadding)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the PC's live dashboard and history")
        }
        .task(id: deviceId) { await model.poll() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let s = model.summary
        if let s, s.online {
            VStack(alignment: .leading, spacing: 12) {
                if let name = s.displayGame {
                    HStack(spacing: 8) {
                        PcGameIcon(game: PcGameStore.shared.game(s.game), size: 22)
                        Text("Playing \(name)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(s.cardMetrics, id: \.label) { m in metric(m) }
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
                Text(s == nil ? "Loading stats…" : PcStatsCopy.status(online: false, at: s?.at, appDown: appDown, now: now))
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    /// The label's colour.
    static func tint(_ label: String) -> Color {
        JcTheme.muted   // the Jarvis look: labels muted, values white
    }

    /// A usage with its temperature beside it at the same size ("38% · 72°C").
    private func metric(_ m: PcSummary.Metric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(m.value)
                if let t = m.temp {
                    Text("·").foregroundStyle(JcTheme.muted)
                    Text(t)
                }
            }
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(JcTheme.text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            Text(m.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PcStatsCardSection.tint(m.label))
                .lineLimit(1)
        }
        .frame(maxWidth: m.temp == nil ? nil : .infinity, alignment: .leading)
        .layoutPriority(m.temp == nil ? 0 : 1)
        .accessibilityElement(children: .combine)
    }
}
