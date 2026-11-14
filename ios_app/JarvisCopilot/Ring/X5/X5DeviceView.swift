import SwiftUI

/// The X5 screen: what the ring reports, its gestures, and every action it can take.
struct X5DeviceView: View {
    @ObservedObject var manager: X5Manager
    let ring: DiscoveredWearable
    @ObservedObject private var session: X5Session
    @ObservedObject private var sync: X5Sync
    @ObservedObject private var measure: X5MeasureController

    @State private var renaming = false
    @State private var showingSettings = false
    @State private var findToken = 0
    @State private var touchToken = 0
    @State private var actionError: String?
    @State private var choosingWorkout = false

    init(manager: X5Manager, ring: DiscoveredWearable) {
        self.manager = manager
        self.ring = ring
        _session = ObservedObject(wrappedValue: manager.session)
        _sync = ObservedObject(wrappedValue: manager.sync)
        _measure = ObservedObject(wrappedValue: manager.measure)
    }

    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.dismiss) private var dismiss

    private var ready: Bool { manager.state == .ready }
    private var today: RingDaySummary? { manager.store?.day(RingDates.dayKey(Date())).summary }
    private var title: String { WearableNames.shared.name(WearableKeepAlive.x5ring, fallback: ring.name) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                statusLine
                DeviceActionError(text: actionError)
                RingMeasureList(items: measure.types.map { type in
                    RingMeasureList.Item(type: type, state: measure.state(of: type), last: measure.lastReading(type),
                                         control: measure.card(type, from: .ring))
                })
                liveFromRing
                gestures
                workoutLink
                healthLink
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .refreshable { _ = await sync.sync() }
        .jcPageChrome(title)
        .wearableRename(isPresented: $renaming, current: title) {
            WearableNames.shared.rename(WearableKeepAlive.x5ring, to: $0)
        }
        .onAppear {
            // Back from Settings after "Forget": leave, don't reconnect it.
            if manager.forgottenIDs.contains(ring.id) {
                dismiss()
                return
            }
            manager.screenIsOpen = true
            if manager.connected?.id != ring.id || !manager.linkIsUp { manager.connect(ring) }
            if ready { Task { await session.checkWear() } }
        }
        .onDisappear {
            // Settings is a push from here and comes straight back; keep the stream across it.
            guard !showingSettings else { return }
            manager.screenIsOpen = false
            measure.leave(.ring)
        }
        .onChange(of: session.lastGesture) { _, _ in touchToken += 1 }
        .navigationDestination(isPresented: $showingSettings) { X5SettingsView(manager: manager) }
        .toolbar {
            WearableToolbarButton(title: "Sync", icon: "arrow.triangle.2.circlepath", disabled: !ready || sync.isSyncing) {
                Task { _ = await sync.sync() }
            }
            WearableMoreMenu(onRename: { renaming = true }, extra: {
                Button("Find ring", jcIcon: "dot.radiowaves.left.and.right") {
                    findToken += 1
                    measure.start(.heartRate, from: .ring)
                }
            })
        }
    }

    // MARK: Workout

    /// Start a workout on the X5 — the same picker, start screen and live sheet as the R12's.
    private var workoutLink: some View {
        DeviceLink(icon: "figure.run", title: "Start a workout",
                   subtitle: "Heart rate every second, steps and distance") { choosingWorkout = true }
            .workoutPicker(isPresented: $choosingWorkout, wearable: WearableKeepAlive.x5ring)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            X5SceneView(spin: true, entrance: true, pulsing: session.measurement?.isActive == true,
                        flashToken: findToken, touchToken: touchToken, cameraDistance: 5.6)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            HStack(spacing: 7) {
                MetricPill(icon: session.battery?.charging == true ? "bolt.fill" : "battery.75",
                           label: session.battery?.charging == true ? "Charging" : "Battery",
                           value: session.battery.map { "\($0.percent)%" } ?? "—",
                           tint: batteryTint(session.battery?.percent ?? 100) ?? JcTheme.success)
                MetricPill(icon: "heart.fill", label: "Heart rate",
                           value: (session.live.flatMap { $0.heartRate > 0 ? $0.heartRate : nil } ?? today?.heartRateLatest)
                               .map { "\($0) bpm" } ?? "—",
                           tint: JcMetric.heart)
                MetricPill(icon: "figure.walk", label: "Steps",
                           value: (session.live?.steps ?? today?.steps).map { "\($0)" } ?? "—",
                           tint: JcMetric.activity)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? JcTheme.success : JcTheme.amber).frame(width: 7, height: 7)
            Text(manager.state.text)
            if sync.isSyncing {
                JcLoader(size: 12)
                Text("Syncing…")
            } else if let last = sync.lastSync {
                Text("· synced \(last, style: .relative) ago")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(JcTheme.muted)
        .padding(.horizontal, 24)
    }

    // MARK: Live

    private var liveFromRing: some View { DeviceLiveRows(rows: liveRows) }

    private var liveRows: [(String, String)] {
        var rows: [(String, String)] = []
        switch session.wear {
        case .worn: rows.append(("Worn", "On a finger"))
        case .offFinger: rows.append(("Worn", "Off — put it on to measure"))
        case .unknown: break
        }
        if let g = session.lastGesture {
            rows.append(("Last gesture", "\(g.gesture.input.label) · \(g.date.formatted(date: .omitted, time: .shortened))"))
        }
        if let l = session.live {
            if l.heartRate > 0 { rows.append(("Heart rate", "\(l.heartRate) bpm")) }
            if l.spo2 > 0 { rows.append(("SpO₂", "\(l.spo2)%")) }
            if l.celsius > 0 { rows.append(("Skin temperature", TemperatureUnit.current.format(l.celsius))) }
            rows.append(("Steps today", "\(l.steps) · \(String(format: "%.2f kcal · %.2f km", l.kcal, l.km))"))
            if l.exerciseMinutes > 0 { rows.append(("Exercise", "\(l.exerciseMinutes) min")) }
        }
        if session.touchAsleep { rows.append(("Touch", "Asleep — it wakes when Jarvis re-arms it")) }
        return rows
    }

    // MARK: Gestures

    /// The mode the ring actually reports, in the inputs screen's terms.
    private var ringMode: RingInputMode {
        guard let hid = session.hid else { return manager.inputs?.wantedMode ?? .off }
        guard hid.enabled else { return .off }
        switch hid.mode {
        case .keys: return .jarvis
        case .shortVideo: return .shortVideo
        case .music: return .music
        case .camera: return .camera
        }
    }

    @ViewBuilder private var gestures: some View {
        if let inputs = manager.inputs {
            RingInputsSection(store: inputs, ready: ready, lastInput: manager.lastInput, inputs: RingInput.x5,
                              ringMode: ringMode, sensitivity: nil, lastPressGap: nil, shakeArmed: false,
                              gestureFeed: manager.gestureFeed,
                              onMode: { mode in
                                  inputs.setMode(mode)
                                  Task { await manager.applyInputMode() }
                              },
                              onSensitivity: { _ in },
                              modes: RingInputMode.x5,
                              keepAliveDevice: WearableKeepAlive.x5ring)
            CardGroup(footer: keyboardFooter(inputs.wantedMode)) {
                Row {
                    Picker("Touch stays awake", selection: Binding(
                        get: { manager.awakePolicy },
                        set: { policy in
                            manager.setAwakePolicy(policy)
                            Task { await manager.applyInputMode() }
                        })) {
                        ForEach(X5AwakePolicy.choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(!ready)
                }
            }
        }
    }

    private func keyboardFooter(_ mode: RingInputMode) -> String {
        switch mode {
        case .shortVideo, .music, .camera:
            return "In this mode the ring is a Bluetooth keyboard for iOS: pair it once in Settings → Bluetooth."
        default:
            return "The ring powers its touch surface down after this long; \"always\" wakes it again while it's connected."
        }
    }

    // MARK: Links

    private var healthLink: some View {
        DeviceLink(icon: "heart.text.square.fill", title: "Body Battery, sleep and more",
                   subtitle: HealthRing.current == .x5 ? "Jarvis Health uses this ring" : "In the Health tab") {
            router?.selectedTab = .health
        }
    }

    private var settingsLink: some View {
        DeviceSettingsLink { showingSettings = true }
    }
}

// MARK: - Card

/// The X5's card in the Devices list.
struct X5Card: View {
    let ring: DiscoveredWearable
    let battery: RingBattery?
    let connected: Bool
    var lastSeen: Date? = nil

    var body: some View {
        WearableCard(name: WearableNames.shared.name(WearableKeepAlive.x5ring, fallback: ring.name.isEmpty ? "X5 ring" : ring.name),
                     model: X5Ring.model, rssi: ring.rssi, battery: battery, connected: connected, lastSeen: lastSeen) {
            X5SceneView(spin: true, tilt: 1.0, cameraDistance: 5.6, spinSeconds: 44)
        }
    }
}
