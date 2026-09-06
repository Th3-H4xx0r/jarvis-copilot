import SwiftUI
import Charts

struct ScaleDeviceView: View {
    @ObservedObject var manager: ScaleManager
    let scale: DiscoveredScale
    @StateObject private var history = ScaleHistoryStore.shared
    @AppStorage("scaleDisplayUnit") private var unit: WeightUnit = .kilograms
    @State private var showingSettings = false

    private let blue = Color(red: 0.30, green: 0.62, blue: 1.0)
    private let violet = Color(red: 0.66, green: 0.40, blue: 1.0)
    private let green = Color(red: 0.29, green: 0.82, blue: 0.49)

    private var observation: ScaleObservation? { manager.latestObservation }
    private var connected: Bool { manager.connected?.id == scale.id && manager.state == .ready }
    private var profile: ScaleUserProfile? { history.activeProfile }
    private var readings: [ScaleReading] { history.readings(for: history.activeProfileID) }
    private var metrics: [BodyMetric: Double] {
        guard let observation, let profile else { return [:] }
        return ScaleMetricsCalculator.metrics(weightKg: observation.weightKg,
                                               impedanceOhms: observation.impedanceOhms,
                                               profile: profile)
    }
    private var visualState: ScaleVisualState {
        guard let observation else { return .idle }
        return observation.isStable ? .stable : .measuring
    }
    private var weightNumber: String? {
        observation.map { String(format: "%.1f", unit.value(fromKg: $0.weightKg)) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                if !metrics.isEmpty { composition }
                trend
                recentHistory
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(scale.name.isEmpty ? "ESF551" : scale.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Button {
                    connected ? manager.disconnect() : manager.connect(scale)
                } label: {
                    Image(systemName: connected ? "bluetooth.slash" : "arrow.clockwise")
                }
                .accessibilityLabel(connected ? "Disconnect" : "Reconnect")
            }
        }
        .navigationDestination(isPresented: $showingSettings) {
            ScaleSettingsView(manager: manager, scale: scale)
        }
        .onAppear { if manager.connected?.id != scale.id { manager.connect(scale) } }
        .onDisappear {
            let bridging = BridgeClient.shared.enabled
                && manager.exposedDeviceID.map(BridgeClient.isExposed) == true
            if !showingSettings && !bridging && manager.connected?.id == scale.id {
                manager.disconnect()
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                ScaleSceneView(state: visualState, weightText: weightNumber,
                               entrance: true)
                    .frame(height: 365)
                    .padding(.horizontal, -10)

                VStack { statusLine; Spacer() }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                VStack {
                    Spacer()
                    measurementReadout
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 7) {
                MetricPill(icon: "waveform.path.ecg", label: "Impedance",
                           value: observation?.impedanceOhms.map { "\(Int($0)) Ω" } ?? "—",
                           tint: violet)
                MetricPill(icon: "dot.radiowaves.left.and.right", label: "Signal",
                           value: scale.rssi == 0 ? "Known" : "\(scale.rssi) dBm",
                           tint: signalTint)
                MetricPill(icon: "person.fill", label: "Profile",
                           value: profile?.name ?? "Me", tint: blue)
            }
            .padding(.horizontal, 12)
        }
    }

    private var statusLine: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: connected ? "bluetooth" : "bluetooth.slash")
                    .foregroundStyle(connected ? blue : .secondary)
                Text(connectionText)
            }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var measurementReadout: some View {
        if let observation {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(String(format: "%.1f", unit.value(fromKg: observation.weightKg)))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit.label).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(phaseTint.opacity(0.28)))
            .shadow(color: phaseTint.opacity(0.18), radius: 18)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            VStack(spacing: 2) {
                Text(connected ? "Step on" : "Scale offline")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(connected ? "Bare feet give full body composition" : "Reconnect to start a measurement")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Composition

    private var composition: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Body composition", systemImage: "figure.stand").font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(BodyMetric.allCases.filter { $0 != .weight && metrics[$0] != nil }) { metric in
                    ScaleMetricCard(metric: metric, value: metrics[metric]!, unit: unit)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Trend

    private var trend: some View {
        let recent = Array(readings.prefix(12).reversed())
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Weight trend", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Spacer()
                if let deltaText { Text(deltaText).font(.caption.weight(.semibold)).foregroundStyle(deltaTint) }
            }

            if recent.count > 1 {
                ScaleTrendChart(readings: recent, unit: unit, tint: blue)
                    .frame(height: 170)
            } else {
                Text("Your trend appears after two stable measurements.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 74)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, 16)
    }

    // MARK: - History and settings

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent measurements", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Text("\(readings.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            if readings.isEmpty {
                ContentUnavailableView("No measurements yet", systemImage: "scalemass",
                                       description: Text("Stable readings will be saved automatically."))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                CardGroup {
                    ForEach(Array(readings.prefix(5).enumerated()), id: \.element.id) { index, reading in
                        if index > 0 { RowDivider() }
                        Row(minHeight: 58) {
                            HStack {
                                ZStack {
                                    Circle().fill(blue.opacity(0.14)).frame(width: 34, height: 34)
                                    Image(systemName: "scalemass.fill").font(.caption).foregroundStyle(blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reading.date.formatted(date: .abbreviated, time: .shortened))
                                    if let fat = reading.metrics[.bodyFat] {
                                        Text("\(BodyMetric.bodyFat.format(fat, unit: unit)) body fat")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(unit.format(kg: reading.weightKg)).font(.headline.monospacedDigit())
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsLink: some View {
        CardGroup {
            Button { showingSettings = true } label: {
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

    private var connectionText: String {
        switch manager.state {
        case .connecting, .discovering: return "Connecting"
        case .ready: return "Connected"
        default: return "Disconnected"
        }
    }
    private var phaseTint: Color {
        if observation?.isStable == true { return green }
        if observation != nil { return violet }
        return connected ? blue : .secondary
    }
    private var signalTint: Color {
        switch scale.rssi { case 0: return blue; case (-68)...: return green; case (-82)..<(-68): return .orange; default: return .red }
    }
    private var deltaText: String? {
        guard readings.count >= 2 else { return nil }
        let delta = readings[0].weightKg - readings[1].weightKg
        if abs(delta) < 0.005 { return "No change" }
        let sign = delta > 0 ? "+" : "−"
        return sign + unit.format(kg: abs(delta))
    }
    private var deltaTint: Color {
        guard readings.count >= 2 else { return .secondary }
        return readings[0].weightKg > readings[1].weightKg ? .orange : green
    }
}

/// Preferences and bridge exposure live off the measurement screen, matching the
/// bottle's Settings page and keeping the live scale view focused on weighing.
private struct ScaleSettingsView: View {
    @ObservedObject var manager: ScaleManager
    let scale: DiscoveredScale
    @StateObject private var bridge = BridgeClient.shared
    @StateObject private var history = ScaleHistoryStore.shared
    @AppStorage("scaleDisplayUnit") private var unit: WeightUnit = .kilograms
    @State private var showingProfile = false

    private var profile: ScaleUserProfile? { history.activeProfile }
    private var sharingDeviceID: String {
        manager.exposedDeviceID ?? scale.id.uuidString
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                sharing
                preferences
                device
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingProfile) {
            ScaleProfileEditor(history: history)
        }
    }

    private var sharing: some View {
        CardGroup("Jarvis Copilot",
                  footer: bridge.isPaired
                      ? "Lets Jarvis read this scale's latest measurement and history."
                      : "Pair with a Jarvis Copilot server from the device-list settings first.") {
            Row {
                Toggle("Share with Jarvis", isOn: Binding(
                    get: { BridgeClient.isExposed(sharingDeviceID) },
                    set: { on in
                        BridgeClient.setExposed(on, for: sharingDeviceID)
                        manager.refreshRegistryMembership()
                    }))
            }
            .disabled(!bridge.isPaired)
        }
    }

    private var preferences: some View {
        CardGroup("Preferences") {
            Row {
                HStack {
                    Label("Display unit", systemImage: "ruler")
                    Spacer(minLength: 12)
                    Picker("Display unit", selection: $unit) {
                        ForEach(WeightUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 164)
                }
            }
            RowDivider()
            Button { showingProfile = true } label: {
                Row {
                    HStack {
                        Label(profile?.name ?? "Profile", systemImage: "person.crop.circle")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(profile?.athleteMode == true ? "Athlete mode" : "Standard")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let profile {
                                Text("\(profile.age) yrs · \(Int(profile.heightCm)) cm")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var device: some View {
        CardGroup("Device") {
            Row { LabeledContent("Model", value: "ESF551") }
            RowDivider()
            Row { LabeledContent("Connection", value: manager.state.text) }
            RowDivider()
            Row {
                LabeledContent("Signal", value: scale.rssi == 0 ? "Known" : "\(scale.rssi) dBm")
            }
            RowDivider()
            Row {
                LabeledContent("Bluetooth ID", value: scale.id.uuidString)
                    .font(.body.monospaced())
            }
        }
    }
}

private struct ScaleMetricCard: View {
    let metric: BodyMetric
    let value: Double
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: metric.icon)
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(metric.tint)
                    .frame(width: 30, height: 30).background(metric.tint.opacity(0.15), in: Circle())
                Spacer()
                Circle().fill(metric.tint.opacity(0.65)).frame(width: 6, height: 6)
            }
            Text(metric.format(value, unit: unit))
                .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(metric.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(metric.tint.opacity(0.10)))
    }
}

private struct ScaleTrendChart: View {
    let readings: [ScaleReading]
    let unit: WeightUnit
    let tint: Color
    @State private var selectedDate: Date?

    private var selectedReading: ScaleReading? {
        guard let selectedDate else { return nil }
        return readings.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.map { unit.value(fromKg: $0.weightKg) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max(unit == .kilograms ? 0.5 : 1.0, (high - low) * 0.28)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        Chart {
            ForEach(readings) { reading in
                let value = unit.value(fromKg: reading.weightKg)
                AreaMark(
                    x: .value("Date", reading.date),
                    yStart: .value("Baseline", yDomain.lowerBound),
                    yEnd: .value("Weight", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.015)],
                    startPoint: .top, endPoint: .bottom))

                LineMark(x: .value("Date", reading.date),
                         y: .value("Weight", value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                           lineJoin: .round))
                    .foregroundStyle(tint)
            }

            if let latest = readings.last, selectedReading == nil {
                PointMark(x: .value("Latest date", latest.date),
                          y: .value("Latest weight", unit.value(fromKg: latest.weightKg)))
                    .symbolSize(52)
                    .foregroundStyle(tint)
            }

            if let selectedReading {
                RuleMark(x: .value("Selected date", selectedReading.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.55))

                PointMark(x: .value("Selected date", selectedReading.date),
                          y: .value("Selected weight",
                                    unit.value(fromKg: selectedReading.weightKg)))
                    .symbolSize(74)
                    .foregroundStyle(tint)
                    .annotation(position: .top, spacing: 8) {
                        VStack(spacing: 2) {
                            Text(unit.format(kg: selectedReading.weightKg))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Text(selectedReading.date.formatted(date: .abbreviated,
                                                                time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 10,
                                                         style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08)))
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisTick().foregroundStyle(.secondary.opacity(0.28))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number, format: .number.precision(.fractionLength(0...1)))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("Weight history chart")
        .accessibilityHint("Drag across the chart to inspect saved measurements")
    }
}

private struct ScaleProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var history: ScaleHistoryStore
    @State private var draft = ScaleUserProfile()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $draft.name)
                    Picker("Sex", selection: $draft.sex) {
                        ForEach(BiologicalSex.allCases) { Text($0.label).tag($0) }
                    }
                    DatePicker("Birthday", selection: $draft.birthday, displayedComponents: .date)
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("Height", value: $draft.heightCm,
                                  format: .number.precision(.fractionLength(0...1)))
                        Text("cm").foregroundStyle(.secondary)
                    }
                    Toggle("Athlete mode", isOn: $draft.athleteMode)
                }
                Section {
                    Text("Your profile is used to estimate body-composition metrics from the ESF551's impedance reading.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { history.activeProfile = draft; dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                draft = history.activeProfile ?? ScaleUserProfile()
                loaded = true
            }
        }
    }
}
