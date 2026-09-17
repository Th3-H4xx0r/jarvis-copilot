import SwiftUI

/// Where health analysis is configured: with the wearable, not in Integrations.
///
/// The server refuses a settings write that does not declare it came from here,
/// so this screen is the single owner and the Integrations page only displays
/// what it decided.
struct HealthSettingsSection: View {
    @ObservedObject var health: HealthStore
    let today: String
    @State private var working = false
    @State private var runMessage: String?

    private var settings: HealthSettings? { health.settings }

    var body: some View {
        CardGroup("Health analysis") {
            Row {
                Toggle("Analyse this ring", isOn: Binding(
                    get: { settings?.enabled ?? true },
                    set: { on in write(["enabled": on]) }))
            }
            RowDivider()
            Row {
                Text("The server scores each day from the ring's readings and writes a short summary. Alerts are thresholds against your own baseline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let settings {
                RowDivider()
                Row {
                    Picker("How often", selection: Binding(
                        get: { settings.frequency },
                        set: { value in write(["frequency": value]) })) {
                        ForEach(HealthSettings.frequencies, id: \.self) { option in
                            Text(option.capitalized).tag(option)
                        }
                    }
                }
                RowDivider()
                Row {
                    Picker("Model", selection: Binding(
                        get: { settings.model },
                        set: { value in write(["model": value]) })) {
                        Text("Chat model").tag("")
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                RowDivider()
                Row { sectionLabel("Alerts") }
                ForEach(HealthSettings.ruleOrder, id: \.key) { rule in
                    RowDivider()
                    Row {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(rule.label, isOn: Binding(
                                get: { settings.rules[rule.key]?.enabled ?? true },
                                set: { on in write(["rules": [rule.key: ["enabled": on]]]) }))
                            if settings.rules[rule.key]?.enabled ?? true {
                                Stepper(value: Binding(
                                    get: { settings.rules[rule.key]?.threshold ?? 0 },
                                    set: { value in write(["rules": [rule.key: ["threshold": value]]]) }),
                                        in: rule.range, step: rule.step) {
                                    Text(thresholdText(rule, settings)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                RowDivider()
                Row {
                    HStack {
                        Text("Quiet hours").font(.subheadline)
                        Spacer()
                        Text("\(settings.quietHours.start) – \(settings.quietHours.end)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                RowDivider()
                Row {
                    Text("An alert inside quiet hours waits for the morning instead of waking you.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            RowDivider()
            Row {
                HStack {
                    Button("Run now") { runNow() }
                        .buttonStyle(.plain)
                        .foregroundStyle(JcTheme.accent)
                    Spacer()
                    if working { ProgressView().controlSize(.mini) }
                }
                .font(.subheadline)
            }
            if let runMessage {
                RowDivider()
                Row { Text(runMessage).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = health.lastError {
                RowDivider()
                Row { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .disabled(working)
        .task { await health.refreshSettings() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }

    /// Models the app already offers for chat; the analysis uses the same list.
    private var modelChoices: [String] {
        let stored = UserDefaults.standard.string(forKey: "sel_chat_model") ?? ""
        var out = ["claude-opus-5", "claude-sonnet-5", "gemma4:31b"]
        if !stored.isEmpty, !out.contains(stored) { out.insert(stored, at: 0) }
        if let current = settings?.model, !current.isEmpty, !out.contains(current) { out.insert(current, at: 0) }
        return out
    }

    private func thresholdText(_ rule: (key: String, label: String, unit: String, range: ClosedRange<Double>, step: Double),
                               _ settings: HealthSettings) -> String {
        let value = settings.rules[rule.key]?.threshold ?? 0
        let shown = rule.step < 1 ? String(format: "%.1f", value) : String(Int(value))
        return rule.unit.isEmpty ? shown : "\(shown) \(rule.unit)"
    }

    private func write(_ updates: [String: Any]) {
        working = true
        Task {
            _ = await health.updateSettings(updates)
            working = false
        }
    }

    private func runNow() {
        working = true
        runMessage = nil
        Task {
            let ok = await health.runNow(date: today)
            runMessage = ok ? "Ran just now." : nil
            working = false
        }
    }
}
