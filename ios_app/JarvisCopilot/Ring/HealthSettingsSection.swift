import SwiftUI

/// Where health analysis is configured: with the wearable, not in Integrations.
///
/// The server refuses a settings write that does not declare it came from here,
/// so this screen is the single owner and the Integrations page only displays
/// what it decided.
struct HealthSettingsSection: View {
    @ObservedObject var health: HealthStore
    let today: String
    /// Inside a wearable's own card (under its switch) rather than a card of its own.
    var embedded = false
    @State private var working = false
    @State private var runMessage: String?
    @State private var healthRing = HealthRing.current

    private var settings: HealthSettings? { health.settings }

    var body: some View {
        Group {
            if embedded {
                // Inside the wearable's card: the two groups under their own labels.
                VStack(alignment: .leading, spacing: 0) {
                    JcSectionLabel("Analysis", first: true).padding(.horizontal, JcUnified.cardPadding)
                    analysisRows
                    if let settings {
                        JcRowSeparator(inset: 0)
                        JcSectionLabel("Alerts", first: true).padding(.horizontal, JcUnified.cardPadding)
                        alertRows(settings)
                        JcRowSeparator()
                        quietNote
                            .padding(.horizontal, JcUnified.cardPadding)
                            .padding(.vertical, 12)
                    }
                }
                .tint(JcTheme.accent)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    JcSectionLabel("Analysis", first: true)
                    JcCard(padding: 0) { analysisRows }
                    if let settings {
                        JcSectionLabel("Alerts")
                        JcCard(padding: 0) { alertRows(settings) }
                        quietNote
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                    }
                }
                .tint(JcTheme.accent)
                .padding(.horizontal, JcUnified.pageInset)
            }
        }
        .disabled(working)
        .task { await health.refreshSettings() }
    }

    /// How the server analyses: which ring, its schedule and model, and a run now.
    @ViewBuilder private var analysisRows: some View {
        Text("The server charts your Body Battery from your linked wearables and writes a short summary. Alerts are thresholds against your own baseline.")
            .font(.system(size: 12))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 12)
        JcRowSeparator()

        if HealthRing.bothPaired() {
            JcRow(title: "Ring for Jarvis Health") {
                Picker("Ring for Jarvis Health", selection: Binding(
                    get: { healthRing },
                    set: { ring in
                        healthRing = ring
                        HealthRing.choose(ring)
                    })) {
                    ForEach(HealthRing.allCases.filter { WearableIdentity.remembered($0.kind) != nil }) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .lineLimit(1)
                .layoutPriority(1)
            }
        }

        if let settings {
            JcRow(title: "How often") {
                Picker("How often", selection: Binding(
                    get: { settings.frequency },
                    set: { value in write(["frequency": value]) })) {
                    ForEach(HealthSettings.frequencies, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .lineLimit(1)
                .layoutPriority(1)
            }
            JcRow(title: "Model") {
                Picker("Model", selection: Binding(
                    get: { settings.model },
                    set: { value in write(["model": value]) })) {
                    Text("Chat model").tag("")
                    ForEach(modelChoices, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .lineLimit(1)
                .layoutPriority(1)
            }
        }

        HStack {
            Button("Run now") { runNow() }
                .buttonStyle(.plain)
                .foregroundStyle(JcTheme.accent)
            Spacer()
            if working { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, JcUnified.cardPadding)
        .frame(minHeight: 48)
        if let runMessage {
            JcRowSeparator()
            note(runMessage, color: JcTheme.muted)
        }
        if let error = health.lastError {
            JcRowSeparator()
            note(error, color: JcTheme.amber)
        }
    }

    /// The alert thresholds and the quiet hours they respect.
    @ViewBuilder private func alertRows(_ settings: HealthSettings) -> some View {
        ForEach(HealthSettings.ruleOrder, id: \.key) { rule in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { settings.rules[rule.key]?.enabled ?? true },
                    set: { on in write(["rules": [rule.key: ["enabled": on]]]) })) {
                    Text(rule.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                }
                if settings.rules[rule.key]?.enabled ?? true {
                    Stepper(value: Binding(
                        get: { settings.rules[rule.key]?.threshold ?? 0 },
                        set: { value in write(["rules": [rule.key: ["threshold": value]]]) }),
                            in: rule.range, step: rule.step) {
                        Text(thresholdText(rule, settings)).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                }
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            JcRowSeparator()
        }
        JcRow(title: "Quiet hours", value: "\(settings.quietHours.start) – \(settings.quietHours.end)", last: true)
    }

    private var quietNote: some View {
        Text("An alert inside quiet hours waits for the morning instead of waking you.")
            .font(.system(size: 12))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 10)
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
