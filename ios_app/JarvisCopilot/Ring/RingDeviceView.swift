import SwiftUI

/// The ring screen: everything the ring reports, every action it can take.
struct RingDeviceView: View {
    @ObservedObject var manager: RingManager
    let ring: DiscoveredWearable
    @ObservedObject private var session: RingSession
    @ObservedObject private var sync: RingSync

    @State private var renaming = false
    @State private var showingSettings = false
    @State private var findToken = 0
    @State private var actionError: String?
    @State private var choosingWorkout = false
    @ObservedObject private var measure: RingMeasureController
    @StateObject private var health: HealthStore

    init(manager: RingManager, ring: DiscoveredWearable) {
        self.manager = manager
        self.ring = ring
        _session = ObservedObject(wrappedValue: manager.session)
        _sync = ObservedObject(wrappedValue: manager.sync)
        _measure = ObservedObject(wrappedValue: manager.measure)
        // One store for this screen and the settings it pushes to, addressed by
        // the remembered device id — the same id the server derives its space
        // from. `ring.id` is the fallback only until the ring is remembered.
        _health = StateObject(wrappedValue: HealthStore(
            spaceID: HealthSpace.id(forRing: manager.deviceID ?? ring.id.uuidString)))
    }

    /// Optional so previews and tests without the shell still build the screen.
    @Environment(AppRouter.self) private var router: AppRouter?

    private var ready: Bool { manager.state == .ready }
    private var today: RingDaySummary? { manager.store?.day(RingDates.dayKey(Date())).summary }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                statusLine
                DeviceActionError(text: actionError)
                measureCard
                workoutLink
                // Sleep, heart, stress and the battery are the person's, not the
                // ring's: they live in the Health tab, merged with every other
                // wearable. This screen is about the device.
                healthLink
                liveFromRing
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .refreshable {
            await sync.sync(days: 0)
        }
        .jcPageChrome(WearableNames.shared.name(WearableKeepAlive.ring, fallback: ring.name))
        .wearableRename(isPresented: $renaming, current: WearableNames.shared.name(WearableKeepAlive.ring, fallback: ring.name)) {
            WearableNames.shared.rename(WearableKeepAlive.ring, to: $0)
        }
        .onAppear {
            // A result from an earlier visit is history, not a reading.
            session.clearFinishedMeasurement()
            manager.screenIsOpen = true
            // Load the "put the ring on" hand now, off the main thread, so the
            // sheet never waits on it.
            Task.detached(priority: .utility) { _ = RingHandModel.bundled }
            if manager.connected?.id != ring.id || !manager.linkIsUp { manager.connect(ring) }
        }
        .onDisappear {
            // Settings is a push from here and comes straight back, so keep the sensor running
            // across it rather than stopping and restarting.
            guard !showingSettings else { return }
            manager.screenIsOpen = false
            measure.leave(.ring)
        }
        .ringWearSheet(measure, on: .ring)
        .navigationDestination(isPresented: $showingSettings) {
            RingSettingsView(manager: manager, health: health)
        }
        .toolbar {
            WearableToolbarButton(title: "Sync week", icon: "arrow.triangle.2.circlepath",
                                  disabled: !ready || sync.isSyncing) {
                Task { await sync.sync(days: sync.historyDays) }
            }
            WearableMoreMenu(onRename: { renaming = true },
                             extra: {
                                 Button("Find ring", jcIcon: "dot.radiowaves.left.and.right") {
                                     run {
                                         try await session.findRing()
                                         findToken += 1
                                     }
                                 }
                             })
        }
    }

    /// Start a workout: the ring tracks it with its sensor on the whole time.
    private var workoutLink: some View {
        DeviceLink(icon: "figure.run", title: "Start a workout",
                   subtitle: "Heart rate every second, steps and distance") { choosingWorkout = true }
            .workoutPicker(isPresented: $choosingWorkout, wearable: WearableKeepAlive.ring)
    }

    /// Where this ring's readings went: the Health tab.
    private var healthLink: some View {
        DeviceLink(icon: "heart.text.square.fill", title: "Body Battery, sleep and more",
                   subtitle: "In the Health tab, from every linked wearable") { router?.selectedTab = .health }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            RingSceneView(spin: true, entrance: true,
                          pulsing: session.measurement?.isActive == true, flashToken: findToken, cameraDistance: 5.6)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            HStack(spacing: 7) {
                MetricPill(icon: session.battery?.charging == true ? "bolt.fill" : "battery.75",
                           label: session.battery?.charging == true ? "Charging" : "Battery",
                           value: session.battery.map { "\($0.percent)%" } ?? "—",
                           tint: batteryTint(session.battery?.percent ?? 100) ?? JcTheme.success)
                MetricPill(icon: "heart.fill", label: "Heart rate",
                           value: (session.liveHeartRate.map { Int($0.value) } ?? today?.heartRateLatest).map { "\($0) bpm" } ?? "—",
                           tint: JcMetric.heart)
                MetricPill(icon: "figure.walk", label: "Steps",
                           value: (session.liveActivity?.steps ?? today?.steps).map { "\($0)" } ?? "—",
                           tint: JcMetric.activity)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? JcTheme.success : JcTheme.amber).frame(width: 7, height: 7)
            Text(manager.state.text)
            if sync.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing \(sync.currentStep ?? "")…")
            } else if let last = sync.lastTodaySync {
                Text("· synced \(last, style: .relative) ago")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(JcTheme.muted)
        .padding(.horizontal, 24)
    }

    // MARK: Actions

    private func run(_ work: @escaping () async throws -> Void) {
        actionError = nil
        Task {
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Measure

    /// On-demand readings, one row each — the list Settings would use, rather
    /// than a menu hiding in the toolbar.
    private var measureCard: some View {
        RingMeasureList(items: measure.types.map { type in
            RingMeasureList.Item(type: type, state: measure.state(of: type), last: measure.lastReading(type),
                                 control: measure.card(type, from: .ring))
        })
    }

    // MARK: Live

    private var liveFromRing: some View { DeviceLiveRows(rows: liveRows) }

    private var liveRows: [(String, String)] {
        var rows: [(String, String)] = []
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        if let key = session.lastTouchKey {
            let names = [1: "Swipe down", 2: "Swipe up", 3: "Tap", 4: "Long press"]
            rows.append(("Last touch", "\(names[Int(key.value)] ?? "Key \(Int(key.value))") · \(time(key.date))"))
        }
        if let hr = session.liveHeartRate { rows.append(("Heart rate", "\(Int(hr.value)) bpm · \(time(hr.date))")) }
        if let spo2 = session.liveSpO2 { rows.append(("SpO₂", "\(Int(spo2.value))% · \(time(spo2.date))")) }
        if let temperature = session.liveTemperature {
            rows.append(("Temperature", TemperatureUnit.current.format(temperature.value) + " · " + time(temperature.date)))
        }
        if let activity = session.liveActivity {
            rows.append(("Live steps", "\(activity.steps) · \(String(format: "%.0f kcal", activity.kilocalories))"))
        }
        if let hand = session.settings.wearHand { rows.append(("Worn on", hand.left ? "Left hand" : "Right hand")) }
        if session.findPhoneActive { rows.append(("Find phone", "The ring is looking for this phone")) }
        return rows
    }

    private var settingsLink: some View {
        DeviceSettingsLink { showingSettings = true }
    }
}

// MARK: - Card

/// The ring's card in the Devices list.
struct RingCard: View {
    let ring: DiscoveredWearable
    let battery: RingBattery?
    let connected: Bool
    var lastSeen: Date? = nil

    var body: some View {
        WearableCard(name: WearableNames.shared.name(WearableKeepAlive.ring, fallback: ring.name.isEmpty ? "Smart ring" : ring.name),
                     model: "Colmi R12 smart ring", rssi: ring.rssi, battery: battery, connected: connected,
                     lastSeen: lastSeen) {
            RingSceneView(spin: true, tilt: 1.0, cameraDistance: 5.6, spinSeconds: 44)
        }
    }
}

extension RingMeasurementType {
    var icon: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .bloodPressure: return "drop.fill"
        case .spo2: return "lungs.fill"
        case .healthCheck: return "checkmark.seal.fill"
        case .stress: return "brain.head.profile"
        case .bloodSugar: return "drop.triangle.fill"
        case .hrv: return "waveform.path.ecg"
        case .temperature: return "thermometer.medium"
        }
    }

    var shortLabel: String {
        switch self {
        case .heartRate: return "Heart"
        case .bloodPressure: return "BP"
        case .spo2: return "SpO₂"
        case .healthCheck: return "Check"
        case .stress: return "Stress"
        case .bloodSugar: return "Sugar"
        case .hrv: return "HRV"
        case .temperature: return "Temp"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate: return JcTheme.danger
        case .bloodPressure: return JcTheme.accentAlt
        case .spo2: return JcMetric.oxygen
        case .healthCheck: return JcTheme.speakers[5]   // lime
        case .stress: return JcTheme.amber
        case .bloodSugar: return JcTheme.speakers[3]   // sky
        case .hrv: return JcMetric.rhythm
        case .temperature: return JcTheme.speakers[4]   // peach
        }
    }
}
