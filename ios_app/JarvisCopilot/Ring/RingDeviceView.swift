import SwiftUI

/// The ring screen: everything the ring reports, every action it can take.
struct RingDeviceView: View {
    @ObservedObject var manager: RingManager
    let ring: DiscoveredRing
    @ObservedObject private var session: RingSession
    @ObservedObject private var sync: RingSync

    @State private var dayOffset = 0
    @State private var showingSettings = false
    @State private var findToken = 0
    @State private var actionError: String?

    init(manager: RingManager, ring: DiscoveredRing) {
        self.manager = manager
        self.ring = ring
        _session = ObservedObject(wrappedValue: manager.session)
        _sync = ObservedObject(wrappedValue: manager.sync)
    }

    private var ready: Bool { manager.state == .ready }
    private var dayKey: String { RingDates.dayKey(RingDates.midnight(daysAgo: dayOffset)) }
    private var today: RingDaySummary? { manager.store?.day(RingDates.dayKey(Date())).summary }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                statusLine
                actions
                if let measurement = session.measurement { measurementCard(measurement) }
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                dayPicker
                if let store = manager.store {
                    RingStatsSections(store: store, dayKey: dayKey, capabilities: session.capabilities)
                } else {
                    CardGroup {
                        Row { Text("Connect the ring once to start collecting its data.").foregroundStyle(.secondary) }
                    }
                }
                liveFromRing
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .refreshable { await sync.sync(days: dayOffset) }
        .navigationTitle(ring.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            manager.screenIsOpen = true
            if manager.connected?.id != ring.id || !manager.linkIsUp { manager.connect(ring) }
        }
        .onDisappear {
            guard !showingSettings else { return }
            manager.screenIsOpen = false
            manager.releaseIfIdle()
        }
        .navigationDestination(isPresented: $showingSettings) {
            RingSettingsView(manager: manager)
        }
        .toolbar {
            Button("Sync week", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sync.sync(days: sync.historyDays) }
            }
            .disabled(!ready || sync.isSyncing)
        }
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
                           tint: batteryTint(session.battery?.percent ?? 100) ?? Color(red: 0.29, green: 0.82, blue: 0.49))
                MetricPill(icon: "heart.fill", label: "Heart rate",
                           value: (session.liveHeartRate.map { Int($0.value) } ?? today?.heartRateLatest).map { "\($0) bpm" } ?? "—",
                           tint: Color(red: 1, green: 0.35, blue: 0.4))
                MetricPill(icon: "figure.walk", label: "Steps",
                           value: (session.liveActivity?.steps ?? today?.steps).map { "\($0)" } ?? "—",
                           tint: Color(red: 0.3, green: 0.62, blue: 1))
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(manager.state.text)
            if sync.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing \(sync.currentStep ?? "")…")
            } else if let last = sync.lastTodaySync {
                Text("· synced \(last, style: .relative) ago")
            }
            Spacer()
            if let firmware = session.firmware { Text("fw \(firmware)").monospaced() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
    }

    // MARK: Actions

    private var actions: some View {
        let measurements: [RingMeasurementType] = session.capabilities.isKnown
            ? session.capabilities.supportedMeasurements : [.heartRate, .spo2]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
            ActionButton(title: "Find", icon: "dot.radiowaves.left.and.right", isOn: false, tint: .orange) {
                run {
                    try await session.findRing()
                    findToken += 1
                }
            }
            ForEach(measurements, id: \.self) { type in
                ActionButton(title: type.shortLabel, icon: type.icon,
                             isOn: session.measurement?.isActive == true && session.measurement?.type == type,
                             tint: type.tint) {
                    if session.measurement?.isActive == true {
                        session.cancelMeasurement()
                    } else {
                        run { try await session.startMeasurement(type) }
                    }
                }
            }
            ActionButton(title: "Sync", icon: "arrow.triangle.2.circlepath", isOn: sync.isSyncing, tint: .blue) {
                Task { await sync.sync(days: dayOffset) }
            }
        }
        .disabled(!ready)
        .opacity(ready ? 1 : 0.45)
        .padding(.horizontal, 12)
    }

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

    private func measurementCard(_ m: RingMeasurementState) -> some View {
        CardGroup("Measurement") {
            Row(minHeight: 64) {
                HStack(spacing: 14) {
                    Image(systemName: m.type.icon)
                        .font(.title2)
                        .foregroundStyle(m.type.tint)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.type.label).font(.headline)
                        Text(measurementText(m)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if m.isActive {
                        ProgressView()
                        Button("Stop") { session.cancelMeasurement() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func measurementText(_ m: RingMeasurementState) -> String {
        switch m.phase {
        case .measuring:
            return "Hold still — measuring…"
        case .notWorn:
            return "Put the ring on and try again."
        case .failed:
            return m.detail ?? "The measurement failed."
        case .cancelled:
            return "Stopped."
        case .timedOut:
            return "No reading — wear the ring snugly and keep still."
        case .done:
            switch m.type {
            case .bloodPressure:
                return "\(m.systolic ?? 0)/\(m.diastolic ?? 0) mmHg"
            case .temperature:
                return m.celsius.map { String(format: "%.1f °C", $0) } ?? "—"
            case .heartRate:
                return "\(m.value ?? 0) bpm"
            case .spo2:
                return "\(m.value ?? 0)%"
            case .hrv:
                return "\(m.value ?? 0) ms"
            case .healthCheck:
                var parts = ["\(m.value ?? 0)"]
                if let sys = m.systolic, let dia = m.diastolic { parts.append("\(sys)/\(dia) mmHg") }
                return parts.joined(separator: " · ")
            case .stress, .bloodSugar:
                return "\(m.value ?? 0)"
            }
        }
    }

    // MARK: Days

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0...sync.historyDays, id: \.self) { offset in
                    Button {
                        dayOffset = offset
                    } label: {
                        Text(dayLabel(offset))
                            .font(.subheadline.weight(dayOffset == offset ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(dayOffset == offset ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.07),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func dayLabel(_ offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return RingDates.midnight(daysAgo: offset).formatted(.dateTime.weekday(.abbreviated).day())
        }
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
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        if let key = session.lastTouchKey {
            let names = [1: "Swipe down", 2: "Swipe up", 3: "Tap", 4: "Long press"]
            rows.append(("Last touch", "\(names[Int(key.value)] ?? "Key \(Int(key.value))") · \(time(key.date))"))
        }
        if let hr = session.liveHeartRate { rows.append(("Heart rate", "\(Int(hr.value)) bpm · \(time(hr.date))")) }
        if let spo2 = session.liveSpO2 { rows.append(("SpO₂", "\(Int(spo2.value))% · \(time(spo2.date))")) }
        if let temperature = session.liveTemperature {
            rows.append(("Temperature", String(format: "%.1f °C · ", temperature.value) + time(temperature.date)))
        }
        if let activity = session.liveActivity {
            rows.append(("Live steps", "\(activity.steps) · \(String(format: "%.0f kcal", activity.kilocalories))"))
        }
        if let hand = session.settings.wearHand { rows.append(("Worn on", hand.left ? "Left hand" : "Right hand")) }
        if session.findPhoneActive { rows.append(("Find phone", "The ring is looking for this phone")) }
        return rows
    }

    private var settingsLink: some View {
        CardGroup {
            Button {
                showingSettings = true
            } label: {
                Row {
                    HStack {
                        Text("Settings & diagnostics")
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
}

// MARK: - Card

/// The ring's card in the Devices list.
struct RingCard: View {
    let ring: DiscoveredRing
    let battery: RingBattery?
    let connected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                RingSceneView(spin: true, tilt: 1.0, cameraDistance: 5.6, spinSeconds: 44)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(ring.name.isEmpty ? "Smart ring" : ring.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("Colmi R12 smart ring")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: Color(red: 0.29, green: 0.82, blue: 0.49))
                    } else {
                        MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                                   value: ring.rssi == 0 ? "Known" : "\(ring.rssi) dBm", tint: .blue)
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
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
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
        case .heartRate: return Color(red: 1, green: 0.35, blue: 0.4)
        case .bloodPressure: return .pink
        case .spo2: return Color(red: 0.3, green: 0.75, blue: 1)
        case .healthCheck: return .mint
        case .stress: return .purple
        case .bloodSugar: return .teal
        case .hrv: return .indigo
        case .temperature: return .orange
        }
    }
}
