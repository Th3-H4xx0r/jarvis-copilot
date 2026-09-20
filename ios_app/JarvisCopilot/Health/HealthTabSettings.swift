import SwiftUI

/// Jarvis Health's settings: the only place they are edited.
///
/// The Integrations page shows the same values read-only; the server refuses a
/// write that does not come from here (`source: "health-settings"`).
struct HealthTabSettings: View {
    @ObservedObject var model: HealthTabModel
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [HealthRosterDevice] = []
    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @State private var stepsGoal = 10_000
    @State private var activeGoal = 30
    @State private var sleepGoal = 480
    @State private var age = 30
    @State private var saving = false
    @ObservedObject var appleHealth = AppleHealthWriter.shared
    @ObservedObject var healthSync = AppleHealthSync.shared
    @AppStorage("jc.training.unit") private var unit: TrainingUnit = TrainingUnit.regional
    @AppStorage("jc.distance.unit") private var distanceUnit: DistanceUnit = DistanceUnit.regional
    @AppStorage("jc.map.style") private var mapStyle: MapStyle = .standard
    @AppStorage("jc.health.holdWearables") private var holdWearables = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HealthDataSources(devices: devices,
                                      primary: model.health.settings?.primaryDevice ?? "",
                                      onToggle: { key, linked in
                                          Task {
                                              // Linking a wearable is asking for it to be analysed.
                                              if linked, model.health.settings?.enabled == false {
                                                  _ = await model.health.updateSettings(["enabled": true])
                                              }
                                              await model.setLinked(key, linked, reload: .today)
                                              devices = await model.devices()
                                          }
                                      },
                                      onPrimary: { key in
                                          Task { _ = await model.health.updateSettings(["primary_device": key]) }
                                      },
                                      analysis: {
                                          // How the primary wearable is analysed lives in its own
                                          // card, under its switch: off, and it folds away.
                                          HealthSettingsSection(health: model.health, today: RingDates.dayKey(Date()),
                                                                embedded: true)
                                      })
                    personal
                    wearablesCard
                    workoutsCard
                    appleHealthCard
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
                .animation(.easeInOut(duration: 0.25), value: devices.contains(where: \.linked))
            }
            .jcScreen("Health settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                devices = await model.devices()
                await model.health.refreshSettings()
                if let goals = model.health.settings?.goals {
                    stepsGoal = goals.steps
                    activeGoal = goals.activeMinutes
                    sleepGoal = goals.sleepMinutes ?? 480
                }
            }
        }
    }

    /// Whether the wearables stay connected while this tab is open.
    private var wearablesCard: some View {
        CardGroup("Wearables", footer: "Your ring and bottle stay connected while the Health tab is open and in front, so a refresh or a workout starts at once. Leaving the tab, or the app, lets them go.") {
            Row {
                Toggle("Keep connected while Health is open", isOn: $holdWearables)
                    .tint(JcTheme.accent)
            }
        }
    }

    /// How workouts are shown: weights, distance, and the map routes are drawn on.
    var workoutsCard: some View {
        CardGroup("Workouts", footer: "Topo draws OpenTopoMap's contour lines; the layer button on any route map switches too.") {
            unitRow("Weights") {
                Picker("Weights", selection: $unit) {
                    Text("kg").tag(TrainingUnit.kg)
                    Text("lb").tag(TrainingUnit.lb)
                }
            }
            RowDivider()
            unitRow("Distance") {
                Picker("Distance", selection: $distanceUnit) {
                    Text("km").tag(DistanceUnit.km)
                    Text("mi").tag(DistanceUnit.mi)
                }
            }
            RowDivider()
            unitRow("Map", width: 230) {
                Picker("Map", selection: $mapStyle) {
                    ForEach(MapStyle.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private func unitRow<P: View>(_ label: String, width: CGFloat = 120, @ViewBuilder picker: () -> P) -> some View {
        Row {
            HStack {
                Text(label)
                Spacer()
                picker()
                    .pickerStyle(.segmented)
                    .frame(width: width)
            }
        }
    }

    /// Units, goals and the one profile figure the battery reads (age sets the
    /// heart-rate reserve its activity drain is measured against).
    private var personal: some View {
        CardGroup("You", footer: "Goals score your activity and count your sleep debt; age sets the heart-rate zones the battery drains by.") {
            Row {
                Picker("Temperature", selection: Binding(
                    get: { temperatureUnit },
                    set: { unit in
                        temperatureUnit = unit
                        Task { _ = await model.health.updateSettings(["temperature_unit": unit.rawValue]) }
                    })) {
                    ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            RowDivider()
            Row { Stepper("Steps \(stepsGoal.formatted())", value: $stepsGoal, in: 1000...40_000, step: 500) }
            RowDivider()
            Row { Stepper("Active \(activeGoal) min", value: $activeGoal, in: 10...240, step: 5) }
            RowDivider()
            Row {
                Stepper("Sleep \(sleepGoal / 60)h\(sleepGoal % 60 == 0 ? "" : " \(sleepGoal % 60)m")",
                        value: $sleepGoal, in: 300...660, step: 15)
            }
            RowDivider()
            Row { Stepper("Age \(age)", value: $age, in: 10...100) }
            RowDivider()
            Row {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        _ = await model.health.updateSettings([
                            "goals": ["steps": stepsGoal, "active_minutes": activeGoal, "sleep_minutes": sleepGoal],
                            "profile": ["age": age],
                        ])
                        saving = false
                    }
                }
                .disabled(saving)
            }
        }
    }
}

extension HealthTabSettings {
    /// What Jarvis keeps in Apple Health: one switch for all of it, then one
    /// per kind of data.
    var appleHealthCard: some View {
        CardGroup("Apple Health", footer: appleHealth.problem ?? appleHealthFooter) {
            Row {
                Toggle("Sync with Apple Health", isOn: Binding(
                    get: { appleHealth.enabled },
                    set: { on in
                        Task { await appleHealth.setEnabled(on) }
                    }))
                    .tint(JcTheme.accent)
                    .disabled(!appleHealth.isAvailable)
            }
            if appleHealth.enabled {
                ForEach(AppleHealthKind.allCases) { kind in
                    RowDivider()
                    AppleHealthKindRow(kind: kind, access: healthSync.access(kind), isOn: Binding(
                        get: { healthSync.isOn(kind) },
                        set: { healthSync.set(kind, $0) }))
                }
                let unasked = AppleHealthKind.allCases.filter { healthSync.isOn($0) && healthSync.access($0) == .notAsked }
                if !unasked.isEmpty {
                    RowDivider()
                    Row {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Permission needed")
                                Text(unasked.count > 3
                                     ? "\(unasked[0].title), \(unasked[1].title) and \(unasked.count - 2) more"
                                     : unasked.map(\.title).formatted(.list(type: .and)))
                                    .font(.caption)
                                    .foregroundStyle(JcTheme.muted)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Allow") {
                                Task { await healthSync.syncNow() }
                            }
                            .buttonStyle(.jcGlass(compact: true))
                        }
                    }
                }
                RowDivider()
                Row {
                    HStack {
                        Text(syncLine)
                            .font(.subheadline)
                            .foregroundStyle(JcTheme.muted)
                            .contentTransition(.opacity)
                        Spacer()
                        Button(healthSync.syncing ? "Syncing…" : "Sync now") {
                            Task { await healthSync.syncNow() }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(healthSync.syncing)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appleHealth.enabled)
    }

    private var appleHealthFooter: String {
        appleHealth.enabled
            ? "Your ring's days and your weigh-ins are written after each sync, workouts when they end. Writing again replaces, never duplicates."
            : "Keeps your workouts, heart rate, steps, sleep and weight in Apple Health, so they count toward your Activity rings."
    }

    private var syncLine: String {
        guard let last = healthSync.lastSynced else { return "Not synced yet" }
        if Date().timeIntervalSince(last) < 60 { return "Synced just now" }
        return "Synced " + last.formatted(.relative(presentation: .named))
    }
}

/// One kind of data and its switch, with a word when Apple Health won't take it.
struct AppleHealthKindRow: View {
    let kind: AppleHealthKind
    let access: AppleHealthSync.Access
    @Binding var isOn: Bool

    var body: some View {
        Row {
            Toggle(isOn: $isOn) {
                HStack(spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isOn ? JcTheme.accent : JcTheme.muted)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                        if isOn, let note {
                            Text(note).font(.caption).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
            .tint(JcTheme.accent)
        }
    }

    /// Only a refusal needs saying here; not-yet-asked is one row for all.
    private var note: String? {
        access == .denied ? "Off in Settings › Health › Data Access" : nil
    }
}

/// Every wearable feeding Jarvis Health. Unlinking stops its sync and keeps
/// its data out of your day; its history stays, so relinking loses nothing.
struct HealthDataSources<Analysis: View>: View {
    let devices: [HealthRosterDevice]
    var primary: String = ""
    let onToggle: (String, Bool) -> Void
    var onPrimary: (String) -> Void = { _ in }
    /// The analysis settings, shown inside the linked primary wearable's card.
    @ViewBuilder var analysis: () -> Analysis

    private static var footer: String {
        "Unlinked wearables keep their history. The primary one decides sleep and heart when two overlap, and holds how Jarvis Health analyses."
    }

    /// One card per wearable, each with its own switch.
    var body: some View {
        if devices.isEmpty {
            CardGroup("Data sources", footer: Self.footer) {
                CardEmptyBlock(symbol: "applewatch.slash", text: "No wearables yet — pair one in Devices.")
            }
        } else {
            VStack(spacing: 12) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    CardGroup(index == 0 ? "Data sources" : nil,
                              footer: index == devices.count - 1 ? Self.footer : nil) {
                        card(device)
                        if device.linked && device.key == primaryKey {
                            RowDivider()
                            analysis()
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: device.linked)
                }
            }
        }
    }

    private func card(_ device: HealthRosterDevice) -> some View {
                    Row(minHeight: 60) {
                        HStack(spacing: 12) {
                            JcIcon(icon(device.kind))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(device.linked ? JcTheme.accent : JcTheme.muted)
                                .frame(width: 34, height: 34)
                                .background((device.linked ? JcTheme.accent : JcTheme.muted).opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.name ?? device.kind.capitalized).font(.body.weight(.medium))
                                    if device.key == primaryKey {
                                        Text("PRIMARY")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(JcTheme.accent)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(JcTheme.accent.opacity(0.14), in: Capsule())
                                    }
                                }
                                Text(synced(device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Toggle("Linked", isOn: Binding(get: { device.linked },
                                                           set: { onToggle(device.key, $0) }))
                                .labelsHidden()
                                .tint(JcTheme.accent)
                        }
                    }
                    .contextMenu {
                        if device.linked && device.key != primaryKey && Self.reportsDays(device.kind) {
                            Button("Make primary", systemImage: "star") { onPrimary(device.key) }
                        }
                    }
    }

    /// The chosen primary, or the first linked wearable that reports days
    /// (a scale only weighs, so it is never primary).
    private var primaryKey: String {
        primary.isEmpty ? (devices.first(where: { $0.linked && Self.reportsDays($0.kind) })?.key ?? "") : primary
    }

    private static func reportsDays(_ kind: String) -> Bool { kind != "scale" }

    private func synced(_ device: HealthRosterDevice) -> String {
        guard device.linked else { return "Unlinked · history kept" }
        guard let text = device.lastSyncedAt, let date = HealthClient.instant.date(from: text) else {
            return "Linked · not synced yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "ring": return "circle.circle"
        case "watch": return "applewatch"
        case "scale": return "scalemass"
        default: return "sensor"
        }
    }
}

extension HealthDataSources where Analysis == EmptyView {
    init(devices: [HealthRosterDevice], primary: String = "", onToggle: @escaping (String, Bool) -> Void,
         onPrimary: @escaping (String) -> Void = { _ in }) {
        self.init(devices: devices, primary: primary, onToggle: onToggle, onPrimary: onPrimary, analysis: { EmptyView() })
    }
}
