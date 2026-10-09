import SwiftUI

/// The lights' settings — everything Magic Lantern can do: colour, white / temperature,
/// brightness, the 213 effects and speed, scenes, music from the lights' own mic or the phone's,
/// shake, the two timers, wiring and LED count. All of it greys out while they aren't connected.
struct CarLightSettingsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case color = "Colour", effects = "Effects", music = "Music", schedule = "Schedule", setup = "Setup"
        var id: String { rawValue }
    }

    let controllerID: String

    @ObservedObject private var manager: CarLightsManager = .shared
    @ObservedObject private var music: CarLightsMusic = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .color
    @State private var effectTab = 0
    @State private var drafts: [String: Double] = [:]
    @State private var renaming = false
    @State private var newName = ""
    @State private var pixelText = ""
    @State private var reading = false
    @State private var note: String?

    private var controller: CarLightsController? { manager.controllers.first { $0.id == controllerID } }
    private var state: CarLightsState { manager.state(for: controllerID) }
    private var caps: MelkCapabilities { controller?.capabilities ?? MelkCapabilities(name: "") }
    private var target: [String] { [controllerID] }
    private var connected: Bool { manager.link(for: controllerID) == .ready }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    Picker("", selection: $tab) {
                        ForEach(tabs) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    Group {
                        switch tab {
                        case .color: colorTab
                        case .effects: effectsTab
                        case .music: musicTab
                        case .schedule: scheduleTab
                        case .setup: setupTab
                        }
                    }
                    // Away from the car nothing can reach the lights: grey, not silently queued.
                    .disabled(!connected && tab != .setup)
                    .opacity(!connected && tab != .setup ? 0.45 : 1)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle(controller?.name ?? "Lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename lights", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { manager.rename(controllerID, to: newName) }
            }
        }
    }

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .schedule || caps.hasTimers } }

    /// The lights, whether they're reachable, and their power.
    private var header: some View {
        CardGroup {
            Row {
                HStack(spacing: 12) {
                    Circle().fill(connected ? JcTheme.success : JcTheme.muted).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller?.name ?? "Lights").font(.body.weight(.semibold))
                        Text(connected ? state.summary : "Unavailable — the lights aren't connected. Turn the car on and stay near it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connected {
                        Toggle("", isOn: Binding(get: { state.on }, set: { manager.apply(.power($0), to: target) }))
                            .labelsHidden()
                    } else {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Colour

    private var colorTab: some View {
        VStack(spacing: 18) {
            CardGroup("Colour") {
                Row {
                    ColorPicker("Pick a colour", selection: Binding(
                        get: { Color(red: Double(state.color.r) / 255, green: Double(state.color.g) / 255, blue: Double(state.color.b) / 255) },
                        set: { color in
                            let c = UIColor(color).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1]
                            let rgb = c.count >= 3 ? c : [c[0], c[0], c[0]]
                            manager.apply(.color(MelkColor(r: UInt8(max(0, min(255, rgb[0] * 255))),
                                                           g: UInt8(max(0, min(255, rgb[1] * 255))),
                                                           b: UInt8(max(0, min(255, rgb[2] * 255))))), to: target)
                        }), supportsOpacity: false)
                }
                RowDivider()
                Row {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(MelkColor.presets, id: \.name) { preset in
                            Button { manager.apply(.color(preset.color), to: target) } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(red: Double(preset.color.r) / 255, green: Double(preset.color.g) / 255, blue: Double(preset.color.b) / 255))
                                        .frame(width: 32, height: 32)
                                        .overlay(Circle().strokeBorder(.white.opacity(state.mode == .color && state.color == preset.color ? 0.9 : 0.12), lineWidth: 2))
                                    Text(preset.name).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                RowDivider()
                ForEach(["R", "G", "B"], id: \.self) { channel in
                    Row { channelSlider(channel) }
                }
            }
            if caps.hasWhite {
                CardGroup("White") { Row { slider("white", value: state.whiteLevel, unit: "%") { manager.apply(.white($0), to: target) } } }
            }
            if caps.hasTemperature {
                CardGroup("Colour temperature", footer: "Warm on the left, cold on the right.") {
                    Row { slider("cct", value: state.coldPercent, unit: "% cold") { manager.apply(.temperature(coldPercent: $0), to: target) } }
                }
            }
            CardGroup("Brightness") {
                Row {
                    slider("brightness", value: state.brightness, unit: "%", step: 1) { value in
                        let page: Melk.LightMode = state.mode == .white ? .white : state.mode == .temperature ? .temperature : .rgb
                        manager.apply(.brightness(value, page: page), to: target)
                    }
                }
            }
        }
    }

    private func channelSlider(_ channel: String) -> some View {
        let value: UInt8 = channel == "R" ? state.color.r : channel == "G" ? state.color.g : state.color.b
        return HStack {
            Text(channel).font(.caption.weight(.bold)).frame(width: 14)
            Slider(value: Binding(get: { drafts[channel] ?? Double(value) }, set: { drafts[channel] = $0 }), in: 0...255, step: 1) { editing in
                guard !editing, let v = drafts[channel] else { return }
                var c = state.color
                switch channel { case "R": c.r = UInt8(v); case "G": c.g = UInt8(v); default: c.b = UInt8(v) }
                manager.apply(.color(c), to: target)
                drafts[channel] = nil
            }
            .tint(channel == "R" ? .red : channel == "G" ? .green : .blue)
            Text("\(Int(drafts[channel] ?? Double(value)))").font(.caption.monospacedDigit()).frame(width: 34)
        }
    }

    /// A 0–100 slider that sends once the finger lifts, like the app.
    private func slider(_ key: String, value: Int, unit: String, step: Double = 5, send: @escaping (Int) -> Void) -> some View {
        HStack {
            Slider(value: Binding(get: { drafts[key] ?? Double(value) }, set: { drafts[key] = $0 }), in: 0...100, step: step) { editing in
                guard !editing, let v = drafts[key] else { return }
                send(Int(v))
                drafts[key] = nil
            }
            .tint(JcTheme.accent)
            Text("\(Int(drafts[key] ?? Double(value))) \(unit)").font(.caption.monospacedDigit()).frame(minWidth: 52, alignment: .trailing)
        }
    }

    // MARK: Effects

    private var effectsTab: some View {
        VStack(spacing: 18) {
            CardGroup("Speed") { Row { slider("speed", value: state.speed, unit: "") { manager.apply(.speed($0), to: target) } } }
            CardGroup("Effect brightness") {
                Row { slider("effect-brightness", value: state.effectBrightness, unit: "%") { manager.apply(.brightness($0, page: .effects), to: target) } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MelkCatalog.effectTabs) { t in
                        ActionChip(title: t.title, icon: "sparkles", isOn: effectTab == t.id, tint: JcTheme.accent) { effectTab = t.id }
                    }
                    if caps.hasScenes {
                        ActionChip(title: "Scenes", icon: "theatermasks", isOn: effectTab == 99, tint: JcTheme.accent) { effectTab = 99 }
                    }
                }
                .padding(.horizontal, 20)
            }
            CardGroup(effectTab == 99 ? "Scenes" : MelkCatalog.effectTabs.first { $0.id == effectTab }?.title) {
                let items = effectTab == 99 ? MelkCatalog.scenes : (MelkCatalog.effectTabs.first { $0.id == effectTab }?.items ?? [])
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    Button {
                        manager.apply(effectTab == 99 ? .scene(item.id) : .effect(item.id), to: target)
                    } label: {
                        Row {
                            HStack {
                                Text("\(index + 1). \(item.name)")
                                Spacer()
                                if isCurrent(item) { JcIcon("checkmark", size: 14).foregroundStyle(JcTheme.accent) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isCurrent(_ item: MelkCatalog.Item) -> Bool {
        effectTab == 99 ? (state.mode == .scene && state.scene == item.id) : (state.mode == .effect && state.effect == item.id)
    }

    // MARK: Music

    private var musicTab: some View {
        VStack(spacing: 18) {
            CardGroup("Music", footer: caps.hasDeviceMic
                      ? "The lights' own microphone needs nothing from the phone — best in the car. The phone's microphone sends a new colour on every beat."
                      : "These lights have no microphone of their own: the phone's listens instead.") {
                if caps.hasDeviceMic {
                    Row {
                        Toggle("Lights' microphone", isOn: Binding(get: { state.mode == .deviceMic }, set: { on in
                            if on { music.stopPhoneMic() }
                            manager.apply(.deviceMic(on: on), to: target)
                        }))
                    }
                    RowDivider()
                }
                Row {
                    Toggle("Phone microphone", isOn: Binding(get: { music.listening }, set: { on in
                        if on {
                            music.startPhoneMic(for: target)
                        } else {
                            music.stopPhoneMic()
                        }
                    }))
                }
                if let error = music.error {
                    RowDivider()
                    Row { Text(error).font(.caption).foregroundStyle(JcTheme.danger) }
                }
            }
            if caps.hasDeviceMic {
                CardGroup("Microphone effect") {
                    Row {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(0..<8, id: \.self) { i in
                                ActionChip(title: MelkCatalog.micEffects[i], icon: "waveform",
                                           isOn: state.mode == .deviceMic && Int(state.micEffect) == i, tint: JcTheme.accent) {
                                    music.stopPhoneMic()
                                    manager.apply(.micEffect(UInt8(i)), to: target)
                                }
                            }
                        }
                    }
                }
                CardGroup("Microphone sensitivity") {
                    Row { slider("sensitivity", value: state.micSensitivity, unit: "") { manager.apply(.micSensitivity($0), to: target) } }
                }
            }
            CardGroup(footer: "Shake the phone for a random colour on all the lights.") {
                Row { Toggle("Shake to change colour", isOn: $music.shakeEnabled) }
            }
        }
    }

    // MARK: Schedule

    private var scheduleTab: some View {
        VStack(spacing: 18) {
            ForEach(state.timers) { timer in
                CardGroup(timer.slot == .on ? "Schedule on" : "Schedule off") {
                    Row {
                        Toggle(timer.slot == .on ? "Turn the lights on" : "Turn the lights off",
                               isOn: Binding(get: { timer.enabled }, set: { var t = timer; t.enabled = $0; manager.apply(.timer(t), to: target) }))
                    }
                    RowDivider()
                    Row {
                        DatePicker("At", selection: Binding(get: {
                            Calendar.current.date(bySettingHour: timer.hour, minute: timer.minute, second: 0, of: Date()) ?? Date()
                        }, set: { date in
                            var t = timer
                            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                            t.hour = c.hour ?? 0; t.minute = c.minute ?? 0
                            manager.apply(.timer(t), to: target)
                        }), displayedComponents: .hourAndMinute)
                    }
                    RowDivider()
                    Row {
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                let on = timer.days & UInt8(1 << i) != 0
                                Button {
                                    var t = timer
                                    t.days ^= UInt8(1 << i)
                                    manager.apply(.timer(t), to: target)
                                } label: {
                                    Text(String(MelkTimer.weekdays[i].prefix(2)))
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .foregroundStyle(on ? Color.white : .secondary)
                                        .background(on ? JcTheme.accent.opacity(0.55) : Color.white.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Button {
                reading = true
                Task {
                    let read = await manager.readTimers(controllerID)
                    note = read == nil ? "Couldn't read the timers — are the lights on?" : "Timers read from the lights."
                    reading = false
                }
            } label: {
                if reading { ProgressView() } else { Label("Read from the lights", jcIcon: "arrow.clockwise") }
            }
            .buttonStyle(.jcGlass(compact: true))
            .disabled(reading || manager.link(for: controllerID) != .ready)
        }
    }

    // MARK: Setup

    private var setupTab: some View {
        VStack(spacing: 18) {
            CardGroup("Wiring", footer: connected
                      ? "Set once. If red shows as green or blue, change the order until colours match."
                      : "Unavailable — the lights aren't connected.") {
                Row {
                    Picker("Colour order", selection: Binding(get: { state.pinOrder }, set: { manager.apply(.pinOrder($0), to: target) })) {
                        ForEach(MelkPinOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                RowDivider()
                Row {
                    HStack {
                        Text("LEDs on the strip")
                        Spacer()
                        TextField("\(state.pixelCount ?? 60)", text: $pixelText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Button("Set") {
                            if let n = Int(pixelText), Melk.pixelRange.contains(n) {
                                manager.apply(.pixelCount(n), to: target)
                                note = "LED count set to \(n)."
                            } else {
                                note = "The LED count is 10–1000."
                            }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                    }
                }
            }
            .disabled(!connected)
            .opacity(connected ? 1 : 0.45)
            CardGroup("Controller") {
                Row {
                    HStack {
                        Text(controller?.advertisedName ?? "").foregroundStyle(.secondary)
                        Spacer()
                        Button("Rename") { newName = controller?.name ?? ""; renaming = true }.buttonStyle(.jcGlass(compact: true))
                    }
                }
                RowDivider()
                Row {
                    Button(role: .destructive) {
                        manager.forget(controllerID)
                        CarLightsDevice.shared.refreshMembership()
                        dismiss()
                    } label: { Text("Forget these lights") }
                }
            }
        }
    }
}
