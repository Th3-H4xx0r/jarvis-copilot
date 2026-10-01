import SwiftUI

/// The X5 screen: what the ring reports, its gestures, and every action it can take.
struct X5DeviceView: View {
    @ObservedObject var manager: X5Manager
    let ring: DiscoveredRing
    @ObservedObject private var session: X5Session
    @ObservedObject private var sync: X5Sync
    @ObservedObject private var measure: X5MeasureController

    @State private var renaming = false
    @State private var showingSettings = false
    @State private var findToken = 0
    @State private var touchToken = 0
    @State private var actionError: String?

    init(manager: X5Manager, ring: DiscoveredRing) {
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
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                RingMeasureList(items: measure.types.map { type in
                    RingMeasureList.Item(type: type, state: measure.state(of: type), last: measure.lastReading(type),
                                         control: measure.card(type, from: .ring))
                })
                liveFromRing
                gestures
                healthLink
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .refreshable { _ = await sync.sync() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                           tint: batteryTint(session.battery?.percent ?? 100) ?? Color(red: 0.29, green: 0.82, blue: 0.49))
                MetricPill(icon: "heart.fill", label: "Heart rate",
                           value: (session.live.flatMap { $0.heartRate > 0 ? $0.heartRate : nil } ?? today?.heartRateLatest)
                               .map { "\($0) bpm" } ?? "—",
                           tint: Color(red: 1, green: 0.35, blue: 0.4))
                MetricPill(icon: "figure.walk", label: "Steps",
                           value: (session.live?.steps ?? today?.steps).map { "\($0)" } ?? "—",
                           tint: JcTheme.accent)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(manager.state.text)
            if sync.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if let last = sync.lastSync {
                Text("· synced \(last, style: .relative) ago")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
    }

    // MARK: Live

    @ViewBuilder private var liveFromRing: some View {
        let rows = liveRows
        if !rows.isEmpty {
            CardGroup("Live from the ring") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    Row { LabeledContent(row.0, value: row.1) }
                }
            }
        }
    }

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
        CardGroup {
            Button { router?.selectedTab = .health } label: {
                Row(minHeight: 56) {
                    HStack(spacing: 12) {
                        JcIcon("heart.text.square.fill").font(.system(size: 18)).foregroundStyle(JcTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Body Battery, sleep and more").font(.body.weight(.medium))
                            Text(HealthRing.current == .x5 ? "Jarvis Health uses this ring" : "In the Health tab")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsLink: some View {
        CardGroup {
            Button { showingSettings = true } label: {
                Row {
                    HStack {
                        Text("Settings & diagnostics")
                        Spacer()
                        JcIcon("chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Card

/// The X5's card in the Devices list.
struct X5Card: View {
    let ring: DiscoveredRing
    let battery: RingBattery?
    let connected: Bool
    var lastSeen: Date? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                X5SceneView(spin: true, tilt: 1.0, cameraDistance: 5.6, spinSeconds: 44)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(WearableNames.shared.name(WearableKeepAlive.x5ring, fallback: ring.name.isEmpty ? "X5 ring" : ring.name))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(X5Ring.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: Color(red: 0.29, green: 0.82, blue: 0.49))
                    } else if ring.rssi == 0 {
                        DisconnectedPill()
                    } else {
                        MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                                   value: "\(ring.rssi) dBm", tint: JcTheme.accent)
                    }
                    if let battery {
                        MetricPill(icon: battery.charging ? "bolt.fill" : "battery.75", label: "Battery",
                                   value: "\(battery.percent)%",
                                   tint: batteryTint(battery.percent) ?? Color(red: 0.29, green: 0.82, blue: 0.49))
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !connected && ring.rssi == 0)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}
