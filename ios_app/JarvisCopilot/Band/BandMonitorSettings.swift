import SwiftUI

// The band's Health & Monitor settings, grouped as the official G Band app groups them: every
// automatic measurement the band reports (its `B8` switches; one it lacks is left out), the high
// heart-rate alert, overnight SpO2, and the blood-pressure / glucose / blood-component references
// the band measures against (`91`, `89`, `8A`, as the Android SDK writes them).

struct BandMonitorSettings: View {
    @ObservedObject var session: BandSession
    @ObservedObject var scheduler: BandMeasureScheduler
    @State private var controlError: String?
    /// A switch, through the same skill Jarvis uses.
    let invoke: (String, [String: Any]) -> Void

    private enum Item: Hashable {
        case toggle(title: String, icon: String, tint: Color, name: String, metric: String)
        case heartAlarm, oxygen, bpCalibration, glucoseCalibration, componentCalibration
    }

    private struct Group: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private func has(_ name: String) -> Bool { session.settings?.isOn(name) != nil }

    private var phoneManaged: Bool { scheduler.plan.control == .phone }

    private var groups: [Group] {
        func toggle(_ title: String, _ icon: String, _ tint: Color, _ name: String, _ metric: String) -> Item? {
            // Managed by the phone, the band's own measuring switches are off and not shown.
            if phoneManaged, BandMeasurePlan.autoSwitches.contains(name) { return nil }
            return has(name) ? .toggle(title: title, icon: icon, tint: tint, name: name, metric: metric) : nil
        }
        let all: [Group] = [
            Group(title: "Heart health", items: [
                toggle("Heart rate monitor", "heart.fill", .pink, "auto_heart_rate", "heart_rate"),
                toggle("HRV monitor", "waveform.path.ecg", .red, "auto_hrv", "hrv"),
                // The SDK's VPSettingAutomaticPPGTest: pulse rate, and precise sleep goes with it.
                toggle("Pulse rate & precise sleep", "waveform", .pink, "auto_ppg", "ppg"),
                session.supports("heart_rate_alarm") ? .heartAlarm : nil,
            ].compactMap { $0 }),
            Group(title: "Blood pressure", items: [
                toggle("Blood pressure monitor", "heart.text.square.fill", .orange, "auto_blood_pressure", "blood_pressure"),
                session.calibratesBloodPressure ? .bpCalibration : nil,
            ].compactMap { $0 }),
            Group(title: "Blood oxygen", items: [
                session.supports("spo2") && !phoneManaged ? .oxygen : nil,
                toggle("Low blood oxygen alert", "exclamationmark.triangle.fill", JcTheme.blue, "low_spo2_alert", "low_spo2_alert"),
            ].compactMap { $0 }),
            Group(title: "Blood glucose", items: [
                toggle("Blood glucose monitor", "drop.fill", .orange, "auto_blood_glucose", "blood_glucose"),
                session.glucoseCalibrationKind != .none ? .glucoseCalibration : nil,
            ].compactMap { $0 }),
            Group(title: "Blood components", items: [
                toggle("Blood components monitor", "testtube.2", .red, "auto_blood_component", "blood_component"),
                session.calibratesBloodComponents ? .componentCalibration : nil,
            ].compactMap { $0 }),
            Group(title: "Body", items: [
                toggle("Temperature monitor", "thermometer.medium", .orange, "auto_temperature", "temperature"),
                toggle("Stress monitor", "brain.head.profile", .purple, "auto_stress", "stress"),
                toggle("MET monitor", "flame.fill", .orange, "met", "met"),
            ].compactMap { $0 }),
        ]
        return all.filter { !$0.items.isEmpty }
    }

    var body: some View {
        let groups = self.groups
        VStack(spacing: 22) {
            measuring
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                CardGroup(group.title, footer: index == groups.count - 1 ? Self.scheduleNote : nil) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { i, item in
                        if i > 0 { RowDivider() }
                        row(item)
                    }
                }
            }
        }
    }

    /// What this band can't be told (the SDK has both, for other models).
    static let scheduleNote = "On its own the band measures about every 10 minutes into its daily record; its "
        + "firmware takes no interval of its own. Managed by phone, the intervals above are the phone's."

    // MARK: Who measures

    private var control: Binding<BandMeasureControl> {
        Binding(get: { scheduler.plan.control }, set: { next in
            controlError = nil
            Task {
                do { try await scheduler.setControl(next) } catch {
                    controlError = "Connect the band to change this — \(error.localizedDescription)"
                }
            }
        })
    }

    private var measuring: some View {
        CardGroup("Measurements", footer: controlError ?? (phoneManaged
            ? "The phone keeps the band connected and asks it for each reading when it's due; the band's own all-day measuring is off, which saves most of its battery. Sleep and overnight HRV stay on the band."
            : "The band measures on its own all day. Managed by phone, it measures only when the phone asks, on the intervals you set.")) {
            Row(minHeight: 52) {
                HStack {
                    Text("Managed by")
                    Spacer()
                    if scheduler.applying { ProgressView().controlSize(.small) }
                    Picker("Managed by", selection: control) {
                        Text("Band").tag(BandMeasureControl.band)
                        Text("Phone").tag(BandMeasureControl.phone)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                    .disabled(scheduler.applying)
                }
            }
            if phoneManaged {
                ForEach(BandMeasurePlan.types.filter { session.supports($0.name) }, id: \.self) { type in
                    RowDivider()
                    intervalRow(type)
                }
            }
        }
    }

    private func intervalRow(_ type: BandMeasure) -> some View {
        Row(minHeight: 52) {
            HStack {
                BandMonitorLabel(title: type.label, icon: type.icon, tint: type.tint)
                Spacer()
                Picker(type.label, selection: Binding(get: { scheduler.plan.interval(type) },
                                                      set: { scheduler.setInterval($0, for: type) })) {
                    ForEach(BandMeasurePlan.choices, id: \.self) { Text(BandMeasurePlan.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case let .toggle(title, icon, tint, name, metric):
            Toggle(isOn: Binding(get: { session.settings?.isOn(name) ?? false },
                                 set: { invoke("band_set_monitoring", ["metric": metric, "enabled": $0]) })) {
                BandMonitorLabel(title: title, icon: icon, tint: tint)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
        case .heartAlarm:
            link(BandMonitorLabel(title: "High heart rate alert", icon: "bolt.heart.fill", tint: .red),
                 value: session.heartRateAlarm.map { $0.enabled ? "\($0.high) bpm" : "Off" } ?? "—") {
                BandHeartAlarmEditor(session: session)
            }
        case .oxygen:
            BandOxygenRow(session: session, invoke: invoke)
        case .bpCalibration:
            link(BandMonitorLabel(title: "Blood pressure calibration", icon: "plus.circle", tint: .orange),
                 value: session.bpCalibration.map { $0.enabled ? "\($0.systolic)/\($0.diastolic)" : "Off" } ?? "—") {
                BandBPCalibrationEditor(session: session)
            }
        case .glucoseCalibration:
            link(BandMonitorLabel(title: "Blood glucose calibration", icon: "drop.triangle", tint: .orange),
                 value: session.glucoseCalibration.map { $0.enabled ? "On" : "Off" } ?? "—") {
                BandGlucoseCalibrationEditor(session: session)
            }
        case .componentCalibration:
            link(BandMonitorLabel(title: "Blood components calibration", icon: "testtube.2", tint: .red),
                 value: session.componentCalibration.map { $0.enabled ? "On" : "Off" } ?? "—") {
                BandComponentCalibrationEditor(session: session)
            }
        }
    }

    private func link<Destination: View>(_ label: BandMonitorLabel, value: String,
                                         @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            Row(minHeight: 52) {
                HStack {
                    label
                    Spacer()
                    Text(value).foregroundStyle(.secondary).monospacedDigit()
                    JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

struct BandMonitorLabel: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
        }
    }
}

/// Overnight SpO2: on / off and its window.
private struct BandOxygenRow: View {
    @ObservedObject var session: BandSession
    let invoke: (String, [String: Any]) -> Void

    private var schedule: BandOxygenSchedule {
        session.oxygenSchedule ?? BandOxygenSchedule(enabled: false, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(get: { schedule.enabled }, set: { send(enabled: $0) })) {
                BandMonitorLabel(title: "Blood oxygen monitor", icon: "drop.circle.fill", tint: JcTheme.blue)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            if schedule.enabled {
                RowDivider()
                HStack {
                    Text("Overnight").foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("From", selection: time(\.startHour, \.startMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("To", selection: time(\.endHour, \.endMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
        }
    }

    private func time(_ hour: WritableKeyPath<BandOxygenSchedule, Int>,
                      _ minute: WritableKeyPath<BandOxygenSchedule, Int>) -> Binding<Date> {
        Binding(get: { BandTimeOfDay.date(schedule[keyPath: hour] * 60 + schedule[keyPath: minute]) }, set: { date in
            var next = schedule
            let m = BandTimeOfDay.minute(date)
            next[keyPath: hour] = m / 60
            next[keyPath: minute] = m % 60
            send(enabled: next.enabled, next)
        })
    }

    private func send(enabled: Bool, _ s: BandOxygenSchedule? = nil) {
        let s = s ?? schedule
        invoke("band_set_monitoring", ["metric": "spo2", "enabled": enabled,
                                       "start": String(format: "%02d:%02d", s.startHour, s.startMinute),
                                       "end": String(format: "%02d:%02d", s.endHour, s.endMinute)])
    }
}

/// Minutes after midnight ↔ a time of day for the pickers.
enum BandTimeOfDay {
    static func date(_ minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(max(0, minute) * 60))
    }

    static func minute(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: Editors

/// The editors' frame: the form, a Save that writes to the band, and its error.
private struct BandSettingEditor<Content: View>: View {
    let title: String
    let footer: String
    let save: () async throws -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                content
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    saving = true
                    error = nil
                    Task {
                        do {
                            try await save()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        saving = false
                    }
                } label: {
                    HStack {
                        if saving { ProgressView().controlSize(.small) }
                        Text("Save to band").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(JcTheme.accent)
                .disabled(saving)
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen(title)
    }
}

/// A number typed in the unit it is shown in.
private struct BandNumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Double?

    var body: some View {
        Row(minHeight: 50) {
            HStack {
                Text(title)
                Spacer()
                TextField("—", value: $value, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 110)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

private func stepperRow(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int = 1,
                        unit: String) -> some View {
    Stepper(value: value, in: range, step: step) {
        HStack {
            Text(title)
            Spacer()
            Text("\(value.wrappedValue) \(unit)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 50)
}

struct BandHeartAlarmEditor: View {
    @ObservedObject var session: BandSession
    @State private var enabled = false
    @State private var high = 150
    @State private var low = 50

    var body: some View {
        BandSettingEditor(title: "High heart rate alert",
                          footer: "The band vibrates when your heart rate goes above the high mark or below the low one.",
                          save: { try await session.setHeartRateAlarm(enabled: enabled, high: high, low: low) }) {
            CardGroup {
                Toggle("Alert", isOn: $enabled).padding(.horizontal, 16).frame(minHeight: 50)
                RowDivider()
                stepperRow("Above", $high, 80...220, step: 5, unit: "bpm")
                RowDivider()
                stepperRow("Below", $low, 30...100, step: 5, unit: "bpm")
            }
        }
        .onAppear {
            guard let a = session.heartRateAlarm else { return }
            enabled = a.enabled
            high = max(80, min(220, a.high))
            low = max(30, min(100, a.low))
        }
    }
}

struct BandBPCalibrationEditor: View {
    @ObservedObject var session: BandSession
    @State private var enabled = false
    @State private var systolic = 120
    @State private var diastolic = 80

    var body: some View {
        BandSettingEditor(title: "Blood pressure calibration",
                          footer: "Take a reading with a cuff, sitting and rested, then enter it here. With calibration on, the band measures against it.",
                          save: {
                              try await session.setBloodPressureCalibration(
                                  BandBPCalibration(enabled: enabled, systolic: systolic, diastolic: diastolic))
                          }) {
            CardGroup {
                Toggle("Calibrate", isOn: $enabled).padding(.horizontal, 16).frame(minHeight: 50)
                RowDivider()
                stepperRow("Systolic", $systolic, 70...220, unit: "mmHg")
                RowDivider()
                stepperRow("Diastolic", $diastolic, 40...140, unit: "mmHg")
            }
        }
        .onAppear {
            guard let c = session.bpCalibration else { return }
            enabled = c.enabled
            if c.systolic > 0 { systolic = c.systolic }
            if c.diastolic > 0 { diastolic = c.diastolic }
        }
    }
}

struct BandGlucoseCalibrationEditor: View {
    @ObservedObject var session: BandSession
    @AppStorage(GlucoseUnit.key) private var unit: GlucoseUnit = .mmolL
    @State private var enabled = false
    /// Shown-unit values; times in minutes after midnight.
    @State private var meals: [BandGlucoseCalibration.Meal] = Self.blank

    private static let names = ["Breakfast", "Lunch", "Dinner"]
    private static let blank: [BandGlucoseCalibration.Meal] = [
        .init(beforeMinute: 7 * 60, afterMinute: 9 * 60), .init(beforeMinute: 12 * 60, afterMinute: 14 * 60),
        .init(beforeMinute: 18 * 60, afterMinute: 20 * 60),
    ]

    private var single: Bool { session.glucoseCalibrationKind == .single }

    var body: some View {
        BandSettingEditor(title: "Blood glucose calibration",
                          footer: single
                              ? "A reading from a glucose meter: the band's estimate follows it."
                              : "Readings from a glucose meter before and after each meal, and when you took them: the band's estimate follows them. Leave a meal empty to skip it.",
                          save: { try await session.setGlucoseCalibration(calibration) }) {
            CardGroup {
                Toggle("Calibrate", isOn: $enabled).padding(.horizontal, 16).frame(minHeight: 50)
            }
            if single {
                CardGroup {
                    BandNumberRow(title: "Reading", unit: unit.label, value: $meals[0].before)
                }
            } else {
                ForEach(0..<3, id: \.self) { i in
                    CardGroup(Self.names[i]) {
                        timeRow("Before", $meals[i].beforeMinute)
                        RowDivider()
                        BandNumberRow(title: "Before the meal", unit: unit.label, value: $meals[i].before)
                        RowDivider()
                        timeRow("After", $meals[i].afterMinute)
                        RowDivider()
                        BandNumberRow(title: "After the meal", unit: unit.label, value: $meals[i].after)
                    }
                }
            }
        }
        .onAppear {
            guard let c = session.glucoseCalibration else { return }
            enabled = c.enabled
            meals = (0..<3).map { i in
                guard i < c.meals.count else { return Self.blank[i] }
                let m = c.meals[i]
                return .init(beforeMinute: m.beforeMinute ?? Self.blank[i].beforeMinute, before: m.before.map(unit.value),
                             afterMinute: m.afterMinute ?? Self.blank[i].afterMinute, after: m.after.map(unit.value))
            }
        }
    }

    private func timeRow(_ title: String, _ minute: Binding<Int?>) -> some View {
        Row(minHeight: 50) {
            HStack {
                Text(title)
                Spacer()
                DatePicker(title, selection: Binding(get: { BandTimeOfDay.date(minute.wrappedValue ?? 0) },
                                                     set: { minute.wrappedValue = BandTimeOfDay.minute($0) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    /// The form in mmol/L, as the band keeps it.
    private var calibration: BandGlucoseCalibration {
        func mmol(_ v: Double?) -> Double? { v.flatMap { $0 > 0 ? (unit == .mmolL ? $0 : $0 / 18.016) : nil } }
        return BandGlucoseCalibration(enabled: enabled, meals: meals.map {
            .init(beforeMinute: $0.beforeMinute, before: mmol($0.before), afterMinute: $0.afterMinute, after: mmol($0.after))
        })
    }
}

struct BandComponentCalibrationEditor: View {
    @ObservedObject var session: BandSession
    @AppStorage(BloodFatUnit.key) private var fat: BloodFatUnit = .mmolL
    @AppStorage(UricAcidUnit.key) private var uric: UricAcidUnit = .umolL
    @State private var enabled = false
    @State private var uricAcid: Double?
    @State private var cholesterol: Double?
    @State private var triglycerides: Double?
    @State private var hdl: Double?
    @State private var ldl: Double?

    var body: some View {
        BandSettingEditor(title: "Blood components calibration",
                          footer: "Values from a lab blood test: the band's blood-component estimates follow them.",
                          save: { try await session.setBloodComponentCalibration(calibration) }) {
            CardGroup {
                Toggle("Calibrate", isOn: $enabled).padding(.horizontal, 16).frame(minHeight: 50)
            }
            CardGroup {
                BandNumberRow(title: "Uric acid", unit: uric.label, value: $uricAcid)
                RowDivider()
                BandNumberRow(title: "Total cholesterol", unit: fat.label, value: $cholesterol)
                RowDivider()
                BandNumberRow(title: "Triglycerides", unit: fat.label, value: $triglycerides)
                RowDivider()
                BandNumberRow(title: "HDL", unit: fat.label, value: $hdl)
                RowDivider()
                BandNumberRow(title: "LDL", unit: fat.label, value: $ldl)
            }
        }
        .onAppear {
            guard let c = session.componentCalibration else { return }
            enabled = c.enabled
            func shown(_ v: Double, _ f: (Double) -> Double) -> Double? { v > 0 ? f(v) : nil }
            uricAcid = shown(c.uricAcid, uric.value)
            cholesterol = shown(c.cholesterol) { fat.value($0) }
            triglycerides = shown(c.triglycerides) { fat.value($0, triglycerides: true) }
            hdl = shown(c.hdl) { fat.value($0) }
            ldl = shown(c.ldl) { fat.value($0) }
        }
    }

    /// The form in µmol/L and mmol/L, as the band keeps it.
    private var calibration: BandBloodComponentCalibration {
        func mmol(_ v: Double?, _ factor: Double) -> Double { (v ?? 0) / (fat == .mmolL ? 1 : factor) }
        return BandBloodComponentCalibration(
            enabled: enabled, uricAcid: (uricAcid ?? 0) * (uric == .umolL ? 1 : 59.48),
            cholesterol: mmol(cholesterol, 38.67), triglycerides: mmol(triglycerides, 88.57),
            hdl: mmol(hdl, 38.67), ldl: mmol(ldl, 38.67))
    }
}
