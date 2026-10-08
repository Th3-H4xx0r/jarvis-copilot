import SwiftUI

/// Which lamp's settings are open (sheet item).
struct CarLightPick: Identifiable {
    let controllerID: String
    let lampID: String?
    var id: String { (lampID ?? "") + "@" + controllerID }
}

/// The lights' page: the cabin from above with every lamp where it is — tap one for its settings —
/// then quick colour and brightness for all of them, the lamps, and the controllers.
struct CarLightsPage: View {
    @ObservedObject private var manager: CarLightsManager = .shared
    @ObservedObject private var music: CarLightsMusic = .shared
    @State private var pick: CarLightPick?
    @State private var pairing = false
    @State private var brightness: Double?
    private let layout = CarLightLayout.bundled

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    CarLightsPreview(looks: CarLightsScene.looks(layout: layout, manager: manager)) { lamp in open(lamp: lamp) }
                        .frame(height: 430)
                    Text(manager.controllers.isEmpty ? "Pair your lights to control them" : "Tap a light to change it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if manager.controllers.isEmpty {
                    pairPrompt
                } else {
                    quick
                    lampList
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
        .sheet(item: $pick) { pick in
            CarLightSettingsSheet(controllerID: pick.controllerID, lampID: pick.lampID)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $pairing) { CarLightsPairSheet().presentationDetents([.medium, .large]) }
        .onAppear { manager.start() }
    }

    private func open(lamp id: String) {
        guard let lamp = layout.lamps.first(where: { $0.id == id }) else { return }
        guard let controller = CarLightLayout.controllerID(for: lamp, in: manager.controllers) else { pairing = true; return }
        pick = CarLightPick(controllerID: controller, lampID: id)
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

    /// All the lights at once.
    private var quick: some View {
        let first = manager.controllers.first.map { manager.state(for: $0.id) } ?? CarLightsState()
        return CardGroup("All lights") {
            Row {
                Toggle("Lights", isOn: Binding(get: { first.on }, set: { manager.apply(.power($0)) }))
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
                                    .overlay(Circle().strokeBorder(.white.opacity(first.mode == .color && first.color == preset.color ? 0.9 : 0.15),
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
                    Slider(value: Binding(get: { brightness ?? Double(first.brightness) }, set: { brightness = $0 }),
                           in: 0...100, step: 5) { editing in
                        if !editing, let b = brightness { manager.apply(.brightness(Int(b))); brightness = nil }
                    }
                    .tint(JcTheme.accent)
                    Text("\(Int(brightness ?? Double(first.brightness))) %").font(.caption.monospacedDigit()).frame(width: 44)
                }
            }
        }
    }

    private var lampList: some View {
        CardGroup("Lamps", footer: "Lamps on one controller always show the same colour and effect — the lights have no per-lamp address.") {
            ForEach(Array(layout.lamps.enumerated()), id: \.element.id) { index, lamp in
                if index > 0 { RowDivider() }
                Button { open(lamp: lamp.id) } label: {
                    Row {
                        HStack {
                            Circle().fill(color(for: lamp)).frame(width: 10, height: 10)
                            Text(lamp.name)
                            Spacer()
                            Text(controllerName(for: lamp)).font(.caption).foregroundStyle(.secondary)
                            JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var controllerList: some View {
        CardGroup("Controllers") {
            if manager.controllers.isEmpty {
                CardEmptyBlock(symbol: "light.strip.2", text: "None yet.")
            }
            ForEach(Array(manager.controllers.enumerated()), id: \.element.id) { index, c in
                if index > 0 { RowDivider() }
                Button { pick = CarLightPick(controllerID: c.id, lampID: nil) } label: {
                    Row {
                        HStack(spacing: 12) {
                            Circle().fill(manager.link(for: c.id) == .ready ? JcTheme.success : JcTheme.muted).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body.weight(.semibold))
                                Text("\(c.advertisedName) · \(linkText(c.id)) · \(manager.state(for: c.id).summary)")
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
        case .ready: return "Connected"
        case .connecting: return "Waiting for power"
        case .disconnected: return "Away"
        }
    }

    private func controllerName(for lamp: CarLightLayout.Lamp) -> String {
        guard let id = CarLightLayout.controllerID(for: lamp, in: manager.controllers) else { return "Not paired" }
        return manager.controllers.first { $0.id == id }?.name ?? ""
    }

    private func color(for lamp: CarLightLayout.Lamp) -> Color {
        guard let id = CarLightLayout.controllerID(for: lamp, in: manager.controllers) else { return JcTheme.muted }
        let s = manager.state(for: id)
        guard let c = s.displayColor else { return s.on ? JcTheme.accent : JcTheme.muted }
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
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
