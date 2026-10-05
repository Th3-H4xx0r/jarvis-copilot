import SwiftUI

/// The band's card on Devices.
struct BandCard: View {
    let band: DiscoveredRing
    let battery: RingBattery?
    let connected: Bool
    var lastSeen: Date? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                BandSceneView(spin: true, cameraDistance: 5.6)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(WearableNames.shared.name(WearableKeepAlive.band, fallback: band.name.isEmpty ? BandDevice.fallbackName : band.name))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(BandDevice.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: Color(red: 0.29, green: 0.82, blue: 0.49))
                    } else {
                        DisconnectedPill()
                    }
                    if let battery {
                        MetricPill(icon: battery.charging ? "bolt.fill" : "battery.75", label: "Battery",
                                   value: "\(battery.percent)%", tint: JcTheme.accent)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !connected && band.rssi == 0)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

/// The band's page: model, status, spot checks, a workout, find, sync and its settings.
struct BandDeviceView: View {
    @ObservedObject var manager: BandManager
    let band: DiscoveredRing
    @ObservedObject private var session: BandSession
    @ObservedObject private var sync: BandSync
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var showingSettings = false
    @State private var choosingWorkout = false
    @State private var actionError: String?
    @State private var findToken = 0
    /// "Put the band on" for this page's readings.
    @StateObject private var wearAsk: BandWearAsk

    init(manager: BandManager, band: DiscoveredRing) {
        self.manager = manager
        self.band = band
        _session = ObservedObject(wrappedValue: manager.session)
        _sync = ObservedObject(wrappedValue: manager.sync)
        _wearAsk = StateObject(wrappedValue: BandWearAsk(session: manager.session))
    }

    private var ready: Bool { manager.state == .ready }
    private var today: RingDaySummary? { manager.store?.day(RingDates.dayKey(Date())).summary }
    private var title: String { WearableNames.shared.name(WearableKeepAlive.band, fallback: band.name) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                if session.finding { findingBar }
                statusLine
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                measureCard
                workoutLink
                settingsLink
            }
            .padding(.bottom, 40)
        }
        .refreshable { _ = await sync.sync() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .wearableRename(isPresented: $renaming, current: title) {
            WearableNames.shared.rename(WearableKeepAlive.band, to: $0)
        }
        .onAppear {
            if manager.forgottenIDs.contains(band.id) { dismiss(); return }
            manager.screenIsOpen = true
            if manager.connected?.id != band.id || !manager.linkIsUp { manager.connect(band) }
        }
        .onDisappear {
            // Into the band's settings is not leaving: a reading keeps running.
            guard !showingSettings else { return }
            // Leaving the page is "Not now": no reading keeps asking for the band unseen.
            wearAsk.dismiss()
            manager.screenIsOpen = false
        }
        .navigationDestination(isPresented: $showingSettings) { BandSettingsView(manager: manager) }
        .bandWearSheet(wearAsk)
        .sheet(isPresented: $choosingWorkout) {
            let workout = WearablesHub.shared.ring.workout
            WorkoutPicker(wearable: WearableKeepAlive.band,
                          onTemplate: { workout.startStrength(template: $0) }) { sport in workout.start(sport) }
        }
        .toolbar {
            WearableToolbarButton(title: "Sync", icon: "arrow.triangle.2.circlepath", disabled: !ready || sync.isSyncing) {
                Task { _ = await sync.sync() }
            }
            WearableMoreMenu(onRename: { renaming = true }, extra: {
                if session.finding {
                    Button("Stop finding", jcIcon: "stop.circle") { run { try await session.find(false) } }
                } else {
                    Button("Find band", jcIcon: "dot.radiowaves.left.and.right") {
                        findToken += 1
                        run { try await session.find(true) }
                    }
                }
            })
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            BandSceneView(spin: true, entrance: true, flashToken: findToken, cameraDistance: 5.6)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            HStack(spacing: 7) {
                MetricPill(icon: session.battery?.charging == true ? "bolt.fill" : "battery.75",
                           label: session.battery?.charging == true ? "Charging" : "Battery",
                           value: session.battery.map { "\($0.percent)%" } ?? "—",
                           tint: batteryTint(session.battery?.percent ?? 100) ?? Color(red: 0.29, green: 0.82, blue: 0.49))
                MetricPill(icon: "heart.fill", label: "Heart rate",
                           value: (session.liveHeartRate ?? today?.heartRateLatest).map { "\($0) bpm" } ?? "—",
                           tint: Color(red: 1, green: 0.35, blue: 0.4))
                MetricPill(icon: "figure.walk", label: "Steps",
                           value: today?.steps.map { "\($0)" } ?? "—", tint: JcTheme.accent)
            }
        }
    }

    /// While the band buzzes to be found: say so, and stop it from here.
    private var findingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(JcTheme.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("The band is buzzing").font(.subheadline.weight(.medium))
            Spacer()
            Button("Stop") { run { try await session.find(false) } }
                .buttonStyle(.jcGlass(compact: true))
        }
        .padding(.horizontal, 24)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(manager.state.text)
            if let firmware = session.handshake?.firmware { Text("· \(firmware)") }
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

    // MARK: Measure

    private var measureCard: some View {
        CardGroup("Measure", footer: "Hold still with the band snug on the wrist; a reading takes about a minute.") {
            ForEach(Array(BandMeasure.allCases.enumerated()), id: \.offset) { index, type in
                if index > 0 { RowDivider() }
                Row(minHeight: 50) {
                    HStack {
                        Text(type.label)
                        Spacer()
                        if session.measuring == type {
                            ProgressView().controlSize(.small)
                        } else if let reading = session.lastReading, reading.measure == type {
                            Text(Self.summary(reading)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button("Measure") { run { try await wearAsk.measure(type) } }
                            .buttonStyle(.jcGlass(compact: true))
                            // A workout has the sensor; readings wait until it ends.
                            .disabled(!ready || session.measuring != nil
                                      || WearablesHub.shared.ring.workout.holdsLink(for: WearableKeepAlive.band))
                    }
                }
            }
        }
    }

    static func summary(_ reading: BandReading) -> String {
        let json = reading.json
        if let s = json["systolic"] as? Int, let d = json["diastolic"] as? Int { return "\(s)/\(d)" }
        for key in ["heart_rate", "spo2", "temperature_c", "value"] {
            if let v = json[key] { return "\(v)" }
        }
        if reading.notWorn { return "Not worn" }
        return (json["status"] as? String)?.replacingOccurrences(of: "_", with: " ") ?? ""
    }

    // MARK: Links

    private var workoutLink: some View {
        CardGroup {
            Button { choosingWorkout = true } label: {
                Row(minHeight: 56) {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(JcTheme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start a workout").font(.body.weight(.medium))
                            Text("Heart rate, steps, distance and calories from the band")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsLink: some View {
        CardGroup {
            Button { showingSettings = true } label: {
                Row(minHeight: 50) {
                    HStack {
                        Text("Band settings")
                        Spacer()
                        JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        actionError = nil
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
        }
    }
}

/// The band's settings: phone alerts, alarms, the sitting nudge, automatic measuring, the
/// heart-rate alarm, raise-to-wake, Keep Alive, the raw log and Forget.
struct BandSettingsView: View {
    @ObservedObject var manager: BandManager
    @ObservedObject private var session: BandSession
    @Environment(\.dismiss) private var dismiss
    @State private var alarms: [BandAlarm] = []
    @State private var error: String?
    @State private var keepAlive = false
    @State private var confirmForget = false

    init(manager: BandManager) {
        self.manager = manager
        _session = ObservedObject(wrappedValue: manager.session)
    }

    private var device: BandDevice { BandDevice(backend: manager) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 24)
                }
                alertsCard
                alarmsCard
                healthCard
                connectionCard
                logCard
                CardGroup {
                    Button(role: .destructive) { confirmForget = true } label: {
                        Row(minHeight: 50) { Text("Forget this band").foregroundStyle(.red) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .jcScreen("Band settings")
        .task {
            guard manager.state == .ready else { return }
            await session.refreshReminders()
            await loadAlarms()
        }
        .onAppear { keepAlive = manager.keepAliveEnabled }
        .confirmationDialog("Forget the band?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task { await manager.forget(); dismiss() }
            }
        } message: {
            Text("Its history stays on this phone.")
        }
    }

    // MARK: Alerts

    private var alertsCard: some View {
        CardGroup("Phone alerts", footer: "Which calls, messages and apps make the band vibrate.") {
            if let alerts = session.alerts {
                let json = alerts.json
                let apps = (json["apps"] as? [String: Bool]) ?? [:]
                toggleRow("Calls", on: json["calls"] as? Bool ?? false) { invoke("band_set_alerts", ["calls": $0]) }
                RowDivider()
                toggleRow("Messages", on: json["messages"] as? Bool ?? false) { invoke("band_set_alerts", ["messages": $0]) }
                ForEach(apps.keys.sorted(), id: \.self) { app in
                    RowDivider()
                    toggleRow(app.capitalized, on: apps[app] ?? false) { on in
                        var next = apps
                        next[app] = on
                        invoke("band_set_alerts", ["apps": next.filter(\.value).map(\.key)])
                    }
                }
            } else {
                Row(minHeight: 50) { Text("Connect the band to see its alerts").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Alarms

    private var alarmsCard: some View {
        CardGroup("Alarms", footer: "Silent vibration alarms on the band.") {
            if alarms.isEmpty {
                Row(minHeight: 50) { Text("No alarms").foregroundStyle(.secondary) }
            }
            ForEach(Array(alarms.enumerated()), id: \.offset) { index, alarm in
                if index > 0 { RowDivider() }
                let json = alarm.json
                Row(minHeight: 50) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(json["time"] as? String ?? "—").monospacedDigit()
                            Text(((json["days"] as? [String]) ?? []).joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete") {
                            invoke("band_set_alarm", ["action": "delete", "id": json["id"] as? Int ?? 0]) { Task { await loadAlarms() } }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                    }
                }
            }
            RowDivider()
            Button {
                let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                let time = String(format: "%02d:00", Calendar.current.component(.hour, from: next))
                invoke("band_set_alarm", ["action": "add", "time": time, "days": BandDevice.weekdays, "enabled": true]) {
                    Task { await loadAlarms() }
                }
            } label: {
                Row(minHeight: 50) { Label("Add an alarm", systemImage: "plus").foregroundStyle(JcTheme.accent) }
            }
            .buttonStyle(.plain)
        }
    }

    private func loadAlarms() async {
        guard manager.state == .ready else { return }
        alarms = (try? await session.readAlarms()) ?? []
    }

    // MARK: Health

    private var healthCard: some View {
        CardGroup("Health", footer: "Automatic measuring runs on the band through the day; SpO2 overnight.") {
            let settings = session.settings?.json ?? [:]
            toggleRow("Sitting reminder", on: session.sedentary?.enabled ?? false) {
                invoke("band_set_sedentary", ["enabled": $0, "interval_minutes": 60])
            }
            RowDivider()
            toggleRow("Auto heart rate", on: settings["auto_heart_rate"] as? Bool ?? false) {
                invoke("band_set_monitoring", ["metric": "heart_rate", "enabled": $0])
            }
            RowDivider()
            toggleRow("Auto blood pressure", on: settings["auto_blood_pressure"] as? Bool ?? false) {
                invoke("band_set_monitoring", ["metric": "blood_pressure", "enabled": $0])
            }
            RowDivider()
            toggleRow("Auto temperature", on: settings["auto_temperature"] as? Bool ?? false) {
                invoke("band_set_monitoring", ["metric": "temperature", "enabled": $0])
            }
            RowDivider()
            toggleRow("Overnight SpO2", on: session.oxygenSchedule?.enabled ?? false) {
                invoke("band_set_monitoring", ["metric": "spo2", "enabled": $0])
            }
            RowDivider()
            toggleRow("Heart-rate alarm", on: session.heartRateAlarm?.enabled ?? false) {
                invoke("band_set_heart_rate_alarm", ["enabled": $0])
            }
            RowDivider()
            toggleRow("Raise to wake", on: session.raiseToWake?.enabled ?? session.handshake?.raiseToWake ?? false) {
                invoke("band_set_raise_to_wake", ["enabled": $0])
            }
        }
    }

    private var connectionCard: some View {
        CardGroup("Connection", footer: "Keep Alive holds the link so readings and alerts arrive at once; off saves battery.") {
            Toggle("Keep Alive", isOn: $keepAlive)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .onChange(of: keepAlive) { _, on in _ = WearablesHub.shared.setKeepAlive(on, for: WearableKeepAlive.band) }
        }
    }

    private var logCard: some View {
        CardGroup("Log") {
            ForEach(session.log.prefix(12)) { entry in
                Text("\(entry.outgoing ? "→" : "←") \(entry.hex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: Helpers

    private func toggleRow(_ title: String, on: Bool, _ change: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { change($0) }))
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }

    /// Settings go through the same skills Jarvis uses, so the screen and the agent agree.
    private func invoke(_ name: String, _ args: [String: Any], then: (() -> Void)? = nil) {
        error = nil
        Task {
            do {
                _ = try await device.invoke(name, args: args)
                then?()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
