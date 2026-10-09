import SwiftUI

/// The lights' page: the cabin from above with the lamps where they are (Arrange lamps moves
/// them), the lights' quick controls, and the controllers. All lamps show the same thing — the
/// lights have no zones — and everything greys out while the lights aren't connected.
struct CarLightsPage: View {
    @ObservedObject private var manager: CarLightsManager = .shared
    @ObservedObject private var store: CarLightLayoutStore = .shared
    @State private var settingsFor: CarLightsController?
    @State private var pairing = false
    @State private var arranging = false
    @State private var brightness: Double?

    private var connected: Bool { manager.anyReady }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack(alignment: .bottomTrailing) {
                    CarLightsPreview(layout: store.layout, look: CarLightsScene.look(manager: manager))
                        .frame(height: 430)
                    Button { arranging = true } label: { Label("Arrange lamps", jcIcon: "slider.horizontal.3") }
                        .buttonStyle(.jcGlass(compact: true))
                        .padding(.trailing, 20)
                }
                if manager.controllers.isEmpty {
                    pairPrompt
                } else {
                    quick
                }
                controllerList
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Car lights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WearableToolbarButton(title: "Add lights", icon: "plus") { pairing = true }
            }
        }
        .sheet(item: $settingsFor) { c in
            CarLightSettingsSheet(controllerID: c.id).presentationDetents([.large])
        }
        .sheet(isPresented: $pairing) { CarLightsPairSheet().presentationDetents([.medium, .large]) }
        .fullScreenCover(isPresented: $arranging) { CarLightsArrangeView() }
        .onAppear { manager.start() }
    }

    private var pairPrompt: some View {
        CardGroup(footer: "Turn the car on so the lights have power, then add them. They show up as MELK-… in the Magic Lantern app.") {
            Row {
                HStack {
                    Text("No lights paired yet").font(.callout)
                    Spacer()
                    Button("Add lights") { pairing = true }.buttonStyle(.jcGlass(compact: true))
                }
            }
        }
    }

    /// All the lights at once — greyed out and "Unavailable" while none is connected.
    private var quick: some View {
        let state = manager.controllers.first.map { manager.state(for: $0.id) } ?? CarLightsState()
        return CardGroup("Lights", footer: connected ? nil : "Unavailable — the lights aren't connected. Turn the car on and stay near it.") {
            Row {
                HStack {
                    Text("Lights")
                    Spacer()
                    if connected {
                        Toggle("", isOn: Binding(get: { state.on }, set: { manager.apply(.power($0)) })).labelsHidden()
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                }
            }
            RowDivider()
            Row {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(MelkColor.presets, id: \.name) { preset in
                            Button { manager.apply(.color(preset.color)) } label: {
                                Circle()
                                    .fill(Color(red: Double(preset.color.r) / 255, green: Double(preset.color.g) / 255,
                                                blue: Double(preset.color.b) / 255))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.white.opacity(state.mode == .color && state.color == preset.color ? 0.9 : 0.15),
                                                                   lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                        }
                    }
                }
            }
            RowDivider()
            Row {
                HStack {
                    JcIcon("sun.max", size: 16).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { brightness ?? Double(state.shownBrightness) }, set: { brightness = $0 }),
                           in: 0...100, step: 5) { editing in
                        if !editing, let b = brightness { manager.apply(.brightness(Int(b))); brightness = nil }
                    }
                    .tint(JcTheme.accent)
                    Text("\(Int(brightness ?? Double(state.shownBrightness))) %").font(.caption.monospacedDigit()).frame(width: 44)
                }
            }
            RowDivider()
            Button { if let first = manager.controllers.first { settingsFor = first } } label: {
                Row {
                    HStack {
                        Text("Colours, effects, music, schedule…")
                        Spacer()
                        JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.45)
    }

    private var controllerList: some View {
        CardGroup("Controllers") {
            if manager.controllers.isEmpty {
                CardEmptyBlock(symbol: "light.strip.2", text: "None yet.")
            }
            ForEach(Array(manager.controllers.enumerated()), id: \.element.id) { index, c in
                if index > 0 { RowDivider() }
                Button { settingsFor = c } label: {
                    Row {
                        HStack(spacing: 12) {
                            Circle().fill(manager.link(for: c.id) == .ready ? JcTheme.success : JcTheme.muted).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body.weight(.semibold))
                                Text("\(c.advertisedName) · \(linkText(c.id))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkText(_ id: String) -> String {
        switch manager.link(for: id) {
        case .ready: return "Connected · \(manager.state(for: id).summary)"
        case .connecting: return "Not connected — waiting for the car"
        case .disconnected: return "Not connected"
        }
    }
}

/// Finds MELK controllers nearby and pairs one.
struct CarLightsPairSheet: View {
    @ObservedObject private var manager: CarLightsManager = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CardGroup(footer: "The car has to be on so the lights have power. Only Magic Lantern (MELK-…) controllers are listed.") {
                    if manager.found.isEmpty {
                        Row {
                            HStack(spacing: 10) {
                                if manager.scanning { ProgressView() }
                                Text(manager.scanning ? "Looking for lights…" : "None found").foregroundStyle(.secondary)
                                Spacer()
                                if !manager.scanning {
                                    Button("Scan again") { manager.scan() }.buttonStyle(.jcGlass(compact: true))
                                }
                            }
                        }
                    }
                    ForEach(Array(manager.found.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { RowDivider() }
                        Row {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.body.weight(.semibold))
                                    Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") {
                                    manager.pair(item)
                                    CarLightsDevice.shared.refreshMembership()
                                    dismiss()
                                }
                                .buttonStyle(.jcGlass(compact: true))
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Add car lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { manager.scan() }
            .onDisappear { manager.stopScan() }
        }
    }
}
