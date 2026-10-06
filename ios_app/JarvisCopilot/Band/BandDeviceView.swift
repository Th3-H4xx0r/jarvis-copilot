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
    /// An ECG running now (its live screen), and the report of the one that just ended.
    @State private var ecgLive = false
    @State private var ecgReport: BandEcgReport?

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
                if let hint = electrodeHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                measureCard
                if let id = manager.deviceID { ecgReportsLink(id) }
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
        .fullScreenCover(isPresented: $ecgLive) {
            BandEcgLiveView(session: session) {
                wearAsk.dismiss()
                ecgLive = false
            }
        }
        .sheet(item: $ecgReport) { report in
            NavigationStack { BandEcgReportView(report: report) }
        }
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

    /// The ring's measure list: each reading's symbol (pulsing while it runs), the number as it
    /// comes in, the result for a moment, then the last one kept with how long ago — Stop while
    /// one runs.
    private var measureCard: some View {
        // A workout has the sensor; readings wait until it ends.
        let workout = WearablesHub.shared.ring.workout.holdsLink(for: WearableKeepAlive.band)
        return RingMeasureList(items: BandMeasure.allCases.map { type in
            RingMeasureList.Item(
                label: type.label, icon: type.icon, tint: type.tint, state: wearAsk.state(of: type),
                last: manager.store?.lastBandReading(type),
                control: RingCardMeasure(
                    state: wearAsk.state(of: type),
                    enabled: ready && !workout && (session.measuring == nil || session.measuring == type),
                    start: { start(type) },
                    stop: { wearAsk.dismiss() }))
        })
    }

    /// ECG and body composition read through the electrode: say so while one runs.
    private var electrodeHint: String? {
        guard let type = session.measuring, type.usesElectrode else { return nil }
        let off = session.lastReading.map { $0.measure == type && $0.leadOff } ?? false
        return off ? "Put a finger on the band's metal top and hold it there." : "Keep your finger on the band's metal top until the reading ends."
    }

    /// A reading from the list. ECG gets its live screen, then its report.
    private func start(_ type: BandMeasure) {
        if type == .ecg { ecgLive = true }
        run {
            do {
                try await wearAsk.measure(type)
            } catch {
                ecgLive = false
                throw error
            }
            guard type == .ecg else { return }
            ecgLive = false
            if let id = manager.deviceID, let latest = BandEcgStore.reports(deviceID: id).first,
               Date().timeIntervalSince(latest.date) < 300 {
                ecgReport = latest
            }
        }
    }

    // MARK: Links

    private func ecgReportsLink(_ deviceID: String) -> some View {
        CardGroup {
            NavigationLink { BandEcgHistoryView(deviceID: deviceID) } label: {
                Row(minHeight: 56) {
                    HStack(spacing: 12) {
                        Image(systemName: BandMeasure.ecg.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(BandMeasure.ecg.tint)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ECG reports").font(.body.weight(.medium))
                            Text("Rhythm, HRV, QTc and risk analysis for each ECG")
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
    /// The app-wide units every band and Health value is drawn in (the band keeps a copy).
    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage(GlucoseUnit.key) private var glucoseUnit: GlucoseUnit = .mmolL
    @AppStorage(BloodFatUnit.key) private var bloodFatUnit: BloodFatUnit = .mmolL
    @AppStorage(UricAcidUnit.key) private var uricAcidUnit: UricAcidUnit = .umolL

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
                BandMonitorSettings(session: session) { name, args in invoke(name, args) }
                remindersCard
                unitsCard
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
            await session.refreshCalibrations()
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

    // MARK: Reminders

    private static let sittingIntervals = [30, 45, 60, 90, 120]

    /// The reminder as the band has it, with `changes` over it (its hours are kept).
    private func sittingArgs(_ changes: [String: Any]) -> [String: Any] {
        (session.sedentary?.json ?? [:]).merging(changes) { _, new in new }
    }

    private var remindersCard: some View {
        CardGroup("Reminders") {
            toggleRow("Sitting reminder", on: session.sedentary?.enabled ?? false) {
                invoke("band_set_sedentary", sittingArgs(["enabled": $0]))
            }
            if session.sedentary?.enabled == true {
                RowDivider()
                Row(minHeight: 50) {
                    HStack {
                        Text("Every")
                        Spacer()
                        Picker("Every", selection: Binding(get: { session.sedentary?.intervalMinutes ?? 60 }, set: { minutes in
                            invoke("band_set_sedentary", sittingArgs(["enabled": true, "interval_minutes": minutes]))
                        })) {
                            ForEach(Self.sittingIntervals, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            RowDivider()
            toggleRow("Raise to wake", on: session.raiseToWake?.enabled ?? session.handshake?.raiseToWake ?? false) {
                invoke("band_set_raise_to_wake", ["enabled": $0])
            }
        }
    }

    private var unitsCard: some View {
        CardGroup("Units", footer: "How readings are shown everywhere in the app. The band keeps the same choice.") {
            unitRow("Temperature", selection: Binding(get: { temperatureUnit }, set: { unit in
                temperatureUnit = unit
                setBandUnit(.temperature, metric: unit == .celsius)
            }), options: TemperatureUnit.allCases, label: \.label)
            RowDivider()
            unitRow("Blood glucose", selection: Binding(get: { glucoseUnit }, set: { unit in
                glucoseUnit = unit
                setBandUnit(.glucose, metric: unit == .mmolL)
            }), options: GlucoseUnit.allCases, label: \.label)
            RowDivider()
            unitRow("Blood fat", selection: Binding(get: { bloodFatUnit }, set: { unit in
                bloodFatUnit = unit
                setBandUnit(.bloodFat, metric: unit == .mmolL)
            }), options: BloodFatUnit.allCases, label: \.label)
            RowDivider()
            unitRow("Uric acid", selection: Binding(get: { uricAcidUnit }, set: { unit in
                uricAcidUnit = unit
                setBandUnit(.uricAcid, metric: unit == .umolL)
            }), options: UricAcidUnit.allCases, label: \.label)
        }
    }

    private func unitRow<U: Hashable & Identifiable>(_ title: String, selection: Binding<U>, options: [U],
                                                     label: KeyPath<U, String>) -> some View {
        Row {
            HStack {
                Text(title)
                Spacer()
                Picker(title, selection: selection) {
                    ForEach(options) { Text($0[keyPath: label]).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
            }
        }
    }

    /// The band's copy follows the app's choice when it's connected; the app's changes at once.
    private func setBandUnit(_ unit: BandSettings.Unit, metric: Bool) {
        Task {
            await HealthUnitSync.sendIfChanged()
            do { try await session.setUnit(unit, metric: metric) } catch { self.error = error.localizedDescription }
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
