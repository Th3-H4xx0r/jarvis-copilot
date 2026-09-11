import SwiftUI

/// Everything configurable on the ring, plus device identity and the raw protocol tools.
struct RingSettingsView: View {
    @ObservedObject var manager: RingManager
    @ObservedObject private var session: RingSession
    @StateObject private var bridge = BridgeClient.shared

    @State private var error: String?
    @State private var working = false
    @State private var goals = GoalsDraft()
    @State private var profile = ProfileDraft()
    @State private var rawHex = ""
    @State private var bigCommand = ""
    @State private var bigPayload = ""
    @State private var rawReplies: [String] = []
    @State private var confirmPowerOff = false
    @State private var confirmReset = false
    @State private var showRawBytes = false

    private struct GoalsDraft: Equatable {
        var steps = 8000
        var kilocalories = 300
        var distanceMeters = 5000
        var sportMinutes = 60
        var sleepMinutes = 480
    }

    private struct ProfileDraft: Equatable {
        var female = false
        var age = 30
        var heightCm = 170
        var weightKg = 70
        var use24Hour = true
        var metric = true
    }

    init(manager: RingManager) {
        self.manager = manager
        _session = ObservedObject(wrappedValue: manager.session)
    }

    private var ready: Bool { manager.state == .ready }
    private var caps: RingCapabilities { session.capabilities }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                sharing
                monitoring
                if let inputs = manager.inputs {
                    RingInputsSection(store: inputs, ready: ready,
                                      sensitivity: caps.gesture ? session.settings.gesture?.strength ?? 1 : nil) { value in
                        apply { try await session.setGestureMode(.music, strength: value) }
                    }
                }
                goalsSection
                profileSection
                preferences
                maintenance
                whatItDoes
                liveSensors
                deviceInfo
                diagnostics
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Ring settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadDrafts)
        .confirmationDialog("Power the ring off?", isPresented: $confirmPowerOff, titleVisibility: .visible) {
            Button("Power off", role: .destructive) { apply { try await session.powerOff() } }
        } message: {
            Text("It turns back on when you put it on its charger. Some firmware restarts instead.")
        }
        .confirmationDialog("Factory reset the ring?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase ring", role: .destructive) { apply { try await session.factoryReset() } }
        } message: {
            Text("This erases the data and settings stored on the ring. History already on this phone is kept.")
        }
    }

    // MARK: Sharing

    @ViewBuilder private var sharing: some View {
        if let deviceID = manager.exposedDeviceID {
            CardGroup("Jarvis Copilot",
                      footer: bridge.isPaired
                          ? "Lets Jarvis read this ring's data and run its commands."
                          : "Pair with a Jarvis Copilot server first — Settings on the device list.") {
                Row {
                    Toggle("Share with Jarvis", isOn: Binding(
                        get: { BridgeClient.isExposed(deviceID) },
                        set: { on in
                            BridgeClient.setExposed(on, for: deviceID)
                            manager.refreshRegistryMembership()
                        }))
                }
                .disabled(!bridge.isPaired)
            }
        }
        CardGroup("Connection", footer: WearableKeepAliveToggle.footer) {
            Row {
                WearableKeepAliveToggle(device: WearableKeepAlive.ring) { on in
                    if on {
                        Task { _ = await manager.ensureConnected(timeout: 10) }
                    } else {
                        manager.releaseIfIdle()
                    }
                }
            }
        }
    }

    // MARK: Monitoring

    private var monitoring: some View {
        let s = session.settings
        return CardGroup("Health monitoring", footer: "The ring measures on its own at these intervals. Shorter intervals cost ring battery.") {
            Row {
                Toggle("Heart rate", isOn: Binding(
                    get: { s.heartRate?.enabled ?? false },
                    set: { on in apply { try await session.setHeartRateMonitoring(enabled: on, intervalMinutes: nil) } }))
            }
            RowDivider()
            Row {
                intervalPicker("Heart-rate interval", options: [5, 10, 15, 30, 60], current: s.heartRate?.intervalMinutes) { minutes in
                    apply { try await session.setHeartRateMonitoring(enabled: s.heartRate?.enabled ?? true, intervalMinutes: minutes) }
                }
            }
            if caps.bloodOxygen {
                RowDivider()
                Row {
                    Toggle("Blood oxygen", isOn: Binding(
                        get: { s.spo2?.enabled ?? false },
                        set: { on in apply { try await session.setSpO2Monitoring(enabled: on) } }))
                }
            }
            if caps.stress {
                RowDivider()
                Row {
                    Toggle("Stress", isOn: Binding(
                        get: { s.stress?.enabled ?? false },
                        set: { on in apply { try await session.setStressMonitoring(enabled: on) } }))
                }
            }
            if caps.hrv {
                RowDivider()
                Row {
                    Toggle("HRV", isOn: Binding(
                        get: { s.hrv?.enabled ?? false },
                        set: { on in apply { try await session.setHRVMonitoring(enabled: on, intervalMinutes: nil) } }))
                }
                if s.hrv?.intervalSupported == true {
                    RowDivider()
                    Row {
                        intervalPicker("HRV interval", options: [10, 15, 30, 60], current: s.hrv?.intervalMinutes) { minutes in
                            apply { try await session.setHRVMonitoring(enabled: s.hrv?.enabled ?? true, intervalMinutes: minutes) }
                        }
                    }
                }
            }
            if caps.anyTemperature {
                RowDivider()
                Row {
                    Toggle("Temperature", isOn: Binding(
                        get: { s.temperature?.enabled ?? false },
                        set: { on in apply { try await session.setTemperatureMonitoring(enabled: on, intervalMinutes: nil) } }))
                }
                RowDivider()
                Row {
                    intervalPicker("Temperature interval", options: [10, 30, 60, 120], current: s.temperature?.intervalMinutes) { minutes in
                        apply { try await session.setTemperatureMonitoring(enabled: s.temperature?.enabled ?? true, intervalMinutes: minutes) }
                    }
                }
            }
        }
        .disabled(!ready || working)
    }

    private func intervalPicker(_ title: String, options: [Int], current: Int?, onPick: @escaping (Int) -> Void) -> some View {
        var choices = options
        if let current, !choices.contains(current) { choices.append(current) }
        if current == nil { choices.insert(0, at: 0) }
        choices.sort()
        return Picker(title, selection: Binding(get: { current ?? 0 }, set: { value in if value > 0 { onPick(value) } })) {
            ForEach(choices, id: \.self) { minutes in
                Text(minutes == 0 ? "—" : "\(minutes) min").tag(minutes)
            }
        }
    }

    // MARK: Goals & profile

    private var goalsSection: some View {
        CardGroup("Daily goals") {
            Row { Stepper("Steps \(goals.steps)", value: $goals.steps, in: 1000...50000, step: 500) }
            RowDivider()
            Row { Stepper("Calories \(goals.kilocalories) kcal", value: $goals.kilocalories, in: 50...3000, step: 50) }
            RowDivider()
            Row {
                Stepper("Distance \(String(format: "%.1f", Double(goals.distanceMeters) / 1000)) km",
                        value: $goals.distanceMeters, in: 500...50000, step: 500)
            }
            RowDivider()
            Row { Stepper("Active \(goals.sportMinutes) min", value: $goals.sportMinutes, in: 10...300, step: 10) }
            RowDivider()
            Row {
                Stepper("Sleep \(goals.sleepMinutes / 60)h \(goals.sleepMinutes % 60)m",
                        value: $goals.sleepMinutes, in: 240...720, step: 30)
            }
            RowDivider()
            Row {
                Button("Save goals") {
                    let draft = goals
                    apply {
                        try await session.setGoals(RingGoals(steps: draft.steps, calories: draft.kilocalories * 1000,
                                                             distanceMeters: draft.distanceMeters,
                                                             sportMinutes: draft.sportMinutes,
                                                             sleepMinutes: draft.sleepMinutes))
                    }
                }
            }
        }
        .disabled(!ready || working)
    }

    private var profileSection: some View {
        CardGroup("Profile", footer: "The ring uses these for calories and distance.") {
            Row {
                Picker("Sex", selection: $profile.female) {
                    Text("Male").tag(false)
                    Text("Female").tag(true)
                }
                .pickerStyle(.segmented)
            }
            RowDivider()
            Row { Stepper("Age \(profile.age)", value: $profile.age, in: 10...100) }
            RowDivider()
            Row { Stepper("Height \(profile.heightCm) cm", value: $profile.heightCm, in: 100...230) }
            RowDivider()
            Row { Stepper("Weight \(profile.weightKg) kg", value: $profile.weightKg, in: 30...200) }
            RowDivider()
            Row { Toggle("24-hour time", isOn: $profile.use24Hour) }
            RowDivider()
            Row { Toggle("Metric units", isOn: $profile.metric) }
            RowDivider()
            Row {
                Button("Save profile") {
                    let draft = profile
                    var value = session.settings.profile
                        ?? RingProfile(use24Hour: true, metric: true, sex: 0, age: 30, heightCm: 170, weightKg: 70,
                                       systolic: 120, diastolic: 90, heartRateWarning: 0, open: 0)
                    value.sex = draft.female ? 1 : 0
                    value.age = draft.age
                    value.heightCm = draft.heightCm
                    value.weightKg = draft.weightKg
                    value.use24Hour = draft.use24Hour
                    value.metric = draft.metric
                    let profileToSave = value
                    apply { try await session.setProfile(profileToSave) }
                }
            }
        }
        .disabled(!ready || working)
    }

    // MARK: Preferences

    @ViewBuilder private var preferences: some View {
        let s = session.settings
        if caps.anyTemperature || caps.doNotDisturb || caps.sedentary {
            CardGroup("Preferences") {
                if caps.anyTemperature {
                    Row {
                        Picker("Temperature unit", selection: Binding(
                            get: { s.temperatureUnit?.celsius ?? true },
                            set: { celsius in apply { try await session.setTemperatureUnit(celsius: celsius) } })) {
                            Text("°C").tag(true)
                            Text("°F").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    RowDivider()
                }
                if caps.doNotDisturb {
                    Row {
                        Toggle("Do not disturb", isOn: Binding(
                            get: { s.dnd?.enabled ?? false },
                            set: { on in
                                var dnd = s.dnd ?? RingDND(enabled: on, startHour: 22, startMinute: 0, endHour: 7,
                                                          endMinute: 0, manual: false)
                                dnd.enabled = on
                                let value = dnd
                                apply { try await session.setDND(value) }
                            }))
                    }
                    if let dnd = s.dnd {
                        RowDivider()
                        Row {
                            LabeledContent("Quiet hours", value: String(format: "%02d:%02d – %02d:%02d",
                                                                        dnd.startHour, dnd.startMinute,
                                                                        dnd.endHour, dnd.endMinute))
                        }
                    }
                    RowDivider()
                }
                if caps.sedentary {
                    Row {
                        Toggle("Sedentary reminder", isOn: Binding(
                            get: { s.sedentary?.enabled ?? false },
                            set: { on in
                                var reminder = s.sedentary ?? RingSedentary(startHour: 9, startMinute: 0, endHour: 18,
                                                                           endMinute: 0, weekMask: 0x7F, cycleMinutes: 60)
                                reminder.weekMask = on ? 0x7F : 0
                                let value = reminder
                                apply { try await session.setSedentary(value) }
                            }))
                    }
                }
            }
            .disabled(!ready || working)
        }
    }

    // MARK: Maintenance

    private var maintenance: some View {
        CardGroup("Maintenance") {
            Row {
                Button("Sync clock") { apply { try await session.syncClock() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowDivider()
            Row {
                Button("Re-read settings from the ring") {
                    apply {
                        await session.refreshSettings()
                        await session.refreshBattery()
                        loadDrafts()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if caps.wearingCalibration {
                RowDivider()
                Row {
                    HStack {
                        Button(session.calibration?.phase == .running ? "Cancel calibration" : "Wearing calibration") {
                            if session.calibration?.phase == .running {
                                apply { await session.cancelCalibration() }
                            } else {
                                apply { try await session.startCalibration() }
                            }
                        }
                        Spacer()
                        Text(calibrationText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            RowDivider()
            Row {
                Button(role: .destructive) {
                    confirmPowerOff = true
                } label: {
                    Label("Power off / restart", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RowDivider()
            Row {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Factory reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .disabled(!ready || working)
    }

    private var calibrationText: String {
        switch session.calibration?.phase {
        case .running?: return "Keep the ring on and still…"
        case .succeeded?: return "Calibrated"
        case .cancelled?: return "Cancelled"
        case .failed(let why)?: return why
        case nil: return ""
        }
    }

    // MARK: Device

    /// What the ring answered when asked — this is what Jarvis gates on, not the firmware's
    /// own flags, which under-report on this model.
    private var whatItDoes: some View {
        CardGroup("What this ring does",
                  footer: "Found by asking the ring for each kind of data, because its advertised "
                      + "feature flags miss things it can actually do.") {
            ForEach(RingFeature.allCases) { feature in
                Row(minHeight: 38) {
                    HStack {
                        Text(feature.label).font(.subheadline)
                        Spacer()
                        switch session.probe.works(feature) {
                        case true?:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case false?:
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        case nil:
                            Text("—").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                RowDivider()
            }
            Row {
                Button(session.isProbing ? "Checking…" : "Check again") {
                    Task { await session.runProbe(force: true) }
                }
                .disabled(!ready || session.isProbing)
            }
        }
    }

    /// What the ring is streaming right now. It has no accelerometer or gyroscope feed —
    /// the protocol carries motion only as steps and sleep — so this is the live sensor set.
    private var liveSensors: some View {
        CardGroup("Live sensors",
                  footer: "Pushed by the ring as they happen. Start a measurement to see the optical "
                      + "sensor working; the ring sends no raw accelerometer or gyroscope data.") {
            infoRow("Heart rate", session.liveHeartRate.map { "\(Int($0.value)) bpm · \(ago($0.date))" } ?? "—")
            RowDivider()
            infoRow("Blood oxygen", session.liveSpO2.map { "\(Int($0.value))% · \(ago($0.date))" } ?? "—")
            RowDivider()
            infoRow("Temperature", session.liveTemperature.map { String(format: "%.1f °C · ", $0.value) + ago($0.date) } ?? "—")
            RowDivider()
            infoRow("Steps", session.liveActivity.map { "\($0.steps) · \($0.distanceMeters) m" } ?? "—")
            RowDivider()
            infoRow("Last input", session.lastTouchKey.map {
                (RingInput(touchKey: Int($0.value))?.label ?? "key \(Int($0.value))") + " · " + ago($0.date)
            } ?? "—")
            RowDivider()
            infoRow("Optical samples", session.livePPG.isEmpty
                    ? "—" : "\(session.livePPG.count) · latest \(session.livePPG.suffix(6).map(String.init).joined(separator: " "))")
            if session.measurement?.isActive == true {
                RowDivider()
                Row { Text("Measuring now").font(.caption).foregroundStyle(.green) }
            }
        }
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var deviceInfo: some View {
        let flags = caps.allFlags
        return CardGroup("Device", footer: "The flags below are what the firmware advertises — "
                         + "\"What this ring does\" above is what it actually answered.") {
            infoRow("Connection", manager.state.text)
            if let name = manager.connected?.name { RowDivider(); infoRow("Name", name) }
            if let firmware = session.firmware { RowDivider(); infoRow("Firmware", firmware) }
            if let hardware = session.hardware { RowDivider(); infoRow("Hardware", hardware) }
            if let battery = session.battery {
                RowDivider()
                infoRow("Battery", "\(battery.percent)%" + (battery.charging ? " · charging" : ""))
            }
            RowDivider()
            infoRow("Large-data chunk", "\(session.chunkSize) bytes")
            if let id = manager.deviceID { RowDivider(); infoRow("Jarvis id", id) }
            if let blockA = caps.blockA { RowDivider(); hexRow("Capabilities A (0x01)", blockA) }
            if let blockB = caps.blockB { RowDivider(); hexRow("Capabilities B (0x3C)", blockB) }
            ForEach(flags.indices, id: \.self) { index in
                RowDivider()
                Row(minHeight: 38) {
                    HStack {
                        Text("\(flags[index].group) · \(flags[index].name)").font(.subheadline)
                        Spacer()
                        Image(systemName: flags[index].on ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(flags[index].on ? Color.green : Color.secondary)
                    }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        Row { LabeledContent(title, value: value) }
    }

    private func hexRow(_ title: String, _ bytes: [UInt8]) -> some View {
        Row(minHeight: 56) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(Data(bytes).hexString).font(.caption.monospaced()).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        CardGroup("Diagnostics", footer: "Bytes go straight to the ring; the checksum and large-data header are added for you.") {
            Row {
                HStack {
                    TextField("Command hex, e.g. 03", text: $rawHex)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button("Send") { sendRaw() }
                        .disabled((Data(hexString: rawHex)?.isEmpty ?? true) || !ready)
                }
            }
            RowDivider()
            Row {
                HStack {
                    TextField("Large-data cmd", text: $bigCommand)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .frame(width: 130)
                    TextField("Payload hex", text: $bigPayload)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button("Send") { sendBigData() }
                        .disabled(UInt8(bigCommand, radix: 16) == nil || Data(hexString: bigPayload) == nil || !ready)
                }
            }
            ForEach(rawReplies.indices, id: \.self) { index in
                RowDivider()
                Row(minHeight: 34) {
                    Text(rawReplies[index]).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            RowDivider()
            Row {
                Toggle("Show raw bytes", isOn: $showRawBytes)
            }
            LogRows(log: session.log, showRaw: showRawBytes)
        }
    }

    /// The decoded command and input log, observed on its own so a busy link redraws
    /// these rows and nothing else.
    private struct LogRows: View {
        @ObservedObject var log: RingLog
        let showRaw: Bool

        var body: some View {
            ForEach(Array(log.entries.prefix(60))) { entry in
                RowDivider()
                Row(minHeight: 44) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.frame.cmd == 0 ? "sparkles"
                                : entry.frame.outbound ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(tint(entry))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline)
                            if !entry.detail.isEmpty {
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.date.formatted(date: .omitted, time: .standard)
                                 + (entry.frame.channel == .bigData ? " · large data" : ""))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if showRaw, entry.frame.cmd != 0 {
                                Text(entry.hex).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        private func tint(_ entry: RingLogEntry) -> Color {
            if entry.frame.isError { return .red }
            if entry.frame.cmd == 0 { return Color(red: 0.6, green: 0.55, blue: 1) }
            return entry.frame.outbound ? .orange : .green
        }
    }

    private func sendRaw() {
        guard let bytes = Data(hexString: rawHex).map({ [UInt8]($0) }), !bytes.isEmpty else { return }
        apply {
            let replies = try await session.sendRaw(bytes)
            rawReplies = replies.isEmpty ? ["(no reply)"] : replies.map(describe)
        }
    }

    private func sendBigData() {
        guard let cmd = UInt8(bigCommand, radix: 16), let payload = Data(hexString: bigPayload) else { return }
        apply {
            let replies = try await session.sendRawBigData(cmd: cmd, payload: [UInt8](payload))
            rawReplies = replies.isEmpty ? ["(no reply)"] : replies.map(describe)
        }
    }

    private func describe(_ inbound: RingInbound) -> String {
        String(format: "%@ 0x%02X%@ ", inbound.channel == .bigData ? "BC" : "CMD", inbound.cmd, inbound.isError ? " ERR" : "")
            + Data(inbound.payload).hexString
    }

    // MARK: Helpers

    private func apply(_ work: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await work()
            } catch let failure {
                error = failure.localizedDescription
            }
            working = false
        }
    }

    private func loadDrafts() {
        if let g = session.settings.goals {
            goals = GoalsDraft(steps: g.steps, kilocalories: max(1, g.calories / 1000), distanceMeters: g.distanceMeters,
                               sportMinutes: g.sportMinutes, sleepMinutes: g.sleepMinutes)
        }
        if let p = session.settings.profile {
            profile = ProfileDraft(female: p.sex == 1, age: p.age, heightCm: p.heightCm, weightKg: p.weightKg,
                                   use24Hour: p.use24Hour, metric: p.metric)
        }
    }
}
