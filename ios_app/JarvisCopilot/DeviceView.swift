import SwiftUI

struct DeviceView: View {
    @ObservedObject var manager: BottleManager
    let bottle: DiscoveredBottle

    /// Persisted across launches; display-only, nothing is written to the bottle.
    @AppStorage("temperatureUnit") private var tempUnit: TemperatureUnit = .celsius

    /// Wall-clock elapsed time for the running cycle.
    @State private var cycleStart: Date?
    @State private var now = Date()
    /// Lags `isSterilising` on the way out so the layout doesn't revert mid-unwind.
    @State private var cinematic = false
    /// Held back until the readings have cleared, so the two don't overlap at the bottom
    /// of the hero during the cross-fade.
    @State private var showReadout = false
    /// True when we opened onto a cycle already in progress — Jarvis or the bottle's own
    /// schedule can start one without us seeing it begin, so the clock can't claim to be
    /// elapsed time.
    @State private var joinedMidCycle = false
    /// Pushing a child fires this view's `onDisappear`, so the disconnect has to know
    /// whether we're navigating deeper or actually leaving the device.
    @State private var showingSettings = false

    private var isSterilising: Bool { manager.status?.isSterilising ?? false }
    private var uv: Color { Color(red: 0.66, green: 0.40, blue: 1.0) }
    private var coolTint: Color { Color(red: 0.30, green: 0.62, blue: 1.0) }
    private var goodTint: Color { Color(red: 0.29, green: 0.82, blue: 0.49) }
    private var ready: Bool { manager.state == .ready }

    /// The device counts *down* from ~99 (confirmed on hardware 1.0.3), so completion is
    /// the complement of the byte it reports.
    private var percentComplete: Int {
        guard let p = manager.status?.steriliseProgress else { return 0 }
        return max(0, min(100, 100 - p))
    }

    // A plain ScrollView rather than a List: grouped-list rows keep their own section
    // margins and clip their content, which is what stopped the 3D view bleeding off
    // screen no matter what listRowInsets said.
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                hero
                quickActions
                everydayControls
                detailsLink
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(bottle.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if manager.connected?.id != bottle.id { manager.connect(bottle) } }
        .onDisappear {
            // Keep the link when bridging: leaving this screen would otherwise
            // unregister the bottle and Jarvis would lose it.
            let bridging = BridgeClient.shared.enabled
                && manager.exposedDeviceID.map(BridgeClient.isExposed) == true
            if !showingSettings && !bridging { manager.disconnect() }
        }
        .navigationDestination(isPresented: $showingSettings) {
            DeviceDetailsView(manager: manager)
        }
        .onChange(of: isSterilising) { _, on in
            syncSteriliseUI(on, joined: false)
        }
        // Status arriving for the first time is not a *change*, so a cycle already
        // running when this screen opens would otherwise never light the UI up.
        .onChange(of: manager.status?.isSterilising) { old, new in
            guard old == nil, new == true else { return }
            syncSteriliseUI(true, joined: true)
        }
        // Only exists while a cycle runs: each tick invalidates the whole body, and it
        // only feeds the m:ss readout.
        .task(id: showReadout) {
            guard showReadout else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { manager.send(.status) }
        }
    }

    // MARK: Hero

    /// One scene throughout. Swapping between two `BottleSceneView`s would tear down and
    /// rebuild the SceneKit scene on every state change, which is what made stopping a
    /// cycle snap back instead of animating.
    @ViewBuilder private var hero: some View {
        VStack(spacing: 14) {
            if bottle.hasModel {
                BottleSceneView(spin: true,
                                entrance: true,
                                sterilising: isSterilising)
                    // An SCNView only draws inside its own bounds, so during a cycle the
                    // frame has to reach past the screen edges.
                    .padding(.horizontal, cinematic ? -40 : 0)
                    .frame(height: cinematic ? 430 : 400)
                    .frame(maxWidth: .infinity)
            }

            if !cinematic, let st = manager.status {
                HStack(spacing: 7) {
                    MetricPill(icon: "thermometer.medium", label: "Water",
                               value: temperatureText(st),
                               tint: temperatureTint(st.temperatureC) ?? coolTint)
                    MetricPill(icon: st.isCharging ? "bolt.fill" : "battery.75",
                               label: st.isCharging ? "Charging" : "Battery",
                               value: "\(st.batteryPercent)%",
                               tint: batteryTint(st.batteryPercent) ?? goodTint)
                    MetricPill(icon: "number", label: "Cycles",
                               value: "\(st.steriliseCount)",
                               tint: uv)
                }
                .transition(.opacity)
            }
        }
        // During a cycle the readings move to the top-left, which the composition leaves
        // empty — the bottle leans away to the bottom-left and the lid rides up-right.
        .overlay(alignment: .topLeading) {
            if cinematic, let st = manager.status {
                VStack(alignment: .leading, spacing: 8) {
                    MetricPill(icon: "thermometer.medium", label: "Water",
                               value: temperatureText(st),
                               tint: temperatureTint(st.temperatureC) ?? coolTint)
                    MetricPill(icon: st.isCharging ? "bolt.fill" : "battery.75",
                               label: st.isCharging ? "Charging" : "Battery",
                               value: "\(st.batteryPercent)%",
                               tint: batteryTint(st.batteryPercent) ?? goodTint)
                }
                .padding(.leading, 16)
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showReadout { steriliseReadout.padding(.bottom, 14) }
        }
    }

    /// Brings the cycle UI in or out. Called both on transition and when a status
    /// frame first reveals a cycle that was already running.
    private func syncSteriliseUI(_ on: Bool, joined: Bool) {
        guard on != showReadout || (on && !cinematic) else { return }
        if on {
            joinedMidCycle = joined
            cycleStart = Date()
            withAnimation(.smooth(duration: 0.5)) { cinematic = true }
            // Let the readings clear the bottom of the hero before the readout lands
            // in the same place.
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.smooth(duration: 0.4)) { showReadout = true }
            }
        } else {
            cycleStart = nil
            joinedMidCycle = false
            withAnimation(.smooth(duration: 0.3)) { showReadout = false }
            // The scene needs ~1.6s to crane back and level out; hold the full-bleed
            // layout until it's nearly home, then dissolve back.
            Task {
                try? await Task.sleep(nanoseconds: 940_000_000)
                withAnimation(.smooth(duration: 0.7)) { cinematic = false }
            }
        }
    }

    /// One ring for how far through the cycle is, one clock for how long it's run.
    @ViewBuilder private var steriliseReadout: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, Double(percentComplete) / 100))
                    .stroke(uv, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percentComplete)%")
                    .font(.system(size: 13, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 54, height: 54)
            .animation(.smooth, value: percentComplete)

            VStack(alignment: .leading, spacing: 1) {
                Text(elapsedText)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(joinedMidCycle ? "since opened" : "elapsed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(uv.opacity(0.30)))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private var elapsedText: String {
        guard let start = cycleStart else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Actions

    @ViewBuilder private var quickActions: some View {
        let s = manager.status
        HStack(spacing: 0) {
            ActionButton(title: isSterilising ? "Stop" : "Sterilise",
                         icon: "sparkles",
                         isOn: isSterilising,
                         tint: uv) {
                manager.send(.sterilise(!isSterilising))
            }
            ActionButton(title: "Auto-clean",
                         icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                         isOn: s?.autoSteriliseEnabled ?? false,
                         tint: Color(red: 0.30, green: 0.62, blue: 1.0)) {
                manager.send(.autoSterilise(!(s?.autoSteriliseEnabled ?? false)))
            }
            ActionButton(title: "Touch lock",
                         icon: (s?.touchLocked ?? false) ? "lock.fill" : "lock.open.fill",
                         isOn: s?.touchLocked ?? false,
                         tint: .orange) {
                manager.send(.touchLock(!(s?.touchLocked ?? false)))
            }
        }
        .disabled(!ready)
        .opacity(ready ? 1 : 0.4)
        .padding(.horizontal, 8)
    }

    // MARK: Controls

    /// Only the settings worth reaching daily. Everything else lives behind Details.
    @ViewBuilder private var everydayControls: some View {
        let s = manager.status
        CardGroup {
            Row {
                HStack {
                    Text("UV intensity")
                    Spacer(minLength: 12)
                    Picker("UV intensity", selection: Binding(
                        get: { s?.uvIntensity ?? .normal },
                        set: { manager.send(.uvIntensity($0)) })) {
                            ForEach(UVIntensity.allCases) { Text($0.label).tag($0) }
                        }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            RowDivider()
            Row {
                Toggle("Drink reminders", isOn: Binding(
                    get: { s?.reminderEnabled ?? false },
                    set: { manager.send(.reminderMaster($0)) }))
            }
        }
        .disabled(!ready)
    }

    @ViewBuilder private var detailsLink: some View {
        CardGroup {
            Button {
                showingSettings = true
            } label: {
                Row {
                    HStack {
                        Text("Settings")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func temperatureText(_ st: BottleStatus) -> String {
        tempUnit == .celsius ? "\(st.temperatureC)°C" : "\(st.temperatureF)°F"
    }
}
