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
    @State private var age = 30
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HealthDataSources(devices: devices,
                                      primary: model.health.settings?.primaryDevice ?? "",
                                      onToggle: { key, linked in
                                          Task {
                                              await model.setLinked(key, linked, reload: .today)
                                              devices = await model.devices()
                                          }
                                      },
                                      onPrimary: { key in
                                          Task { _ = await model.health.updateSettings(["primary_device": key]) }
                                      })
                    HealthSettingsSection(health: model.health, today: RingDates.dayKey(Date()))
                    personal
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
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
                }
            }
        }
    }

    /// Units, goals and the one profile figure the battery reads (age sets the
    /// heart-rate reserve its activity drain is measured against).
    private var personal: some View {
        CardGroup("You", footer: "Goals score your activity; age sets the heart-rate zones the battery drains by.") {
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
            Row { Stepper("Age \(age)", value: $age, in: 10...100) }
            RowDivider()
            Row {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        _ = await model.health.updateSettings([
                            "goals": ["steps": stepsGoal, "active_minutes": activeGoal],
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

/// Every wearable feeding Jarvis Health. Unlinking stops its sync and keeps
/// its data out of your day; its history stays, so relinking loses nothing.
struct HealthDataSources: View {
    let devices: [HealthRosterDevice]
    var primary: String = ""
    let onToggle: (String, Bool) -> Void
    var onPrimary: (String) -> Void = { _ in }

    var body: some View {
        CardGroup("Data sources",
                  footer: "Unlinked wearables keep their history. The primary one decides sleep and heart when two overlap.") {
            if devices.isEmpty {
                CardEmptyBlock(symbol: "applewatch.slash", text: "No wearables yet — pair one in Devices.")
            } else {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { RowDivider() }
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
                        if device.linked && device.key != primaryKey {
                            Button("Make primary", systemImage: "star") { onPrimary(device.key) }
                        }
                    }
                }
            }
        }
    }

    /// The chosen primary, or the first linked device when none was chosen.
    private var primaryKey: String {
        primary.isEmpty ? (devices.first(where: \.linked)?.key ?? "") : primary
    }

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
        default: return "sensor"
        }
    }
}
