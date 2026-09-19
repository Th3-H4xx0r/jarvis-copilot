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
    @ObservedObject private var appleHealth = AppleHealthWriter.shared
    @AppStorage("jc.training.unit") private var unit: TrainingUnit = TrainingUnit.regional

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
                    workouts
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
    /// Where workouts go besides Jarvis Health, and the unit lifts are logged in.
    var workouts: some View {
        CardGroup("Workouts", footer: appleHealth.problem
                  ?? "Every workout — runs, walks, lifting — is saved to Apple Health with its heart rate, calories and distance, so it counts toward your Activity rings.") {
            Row {
                Toggle("Save to Apple Health", isOn: Binding(
                    get: { appleHealth.enabled },
                    set: { on in
                        Task { await appleHealth.setEnabled(on) }
                    }))
                    .tint(JcTheme.accent)
                    .disabled(!appleHealth.isAvailable)
            }
            RowDivider()
            Row {
                HStack {
                    Text("Weights in")
                    Spacer()
                    Picker("Weights in", selection: $unit) {
                        Text("kg").tag(TrainingUnit.kg)
                        Text("lb").tag(TrainingUnit.lb)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
        }
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
