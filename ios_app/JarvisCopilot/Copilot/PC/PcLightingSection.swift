import SwiftUI

/// The PC page's Lighting section: on/off, brightness, part by part (chips or a tap on the model),
/// colours, effects, speed and saved looks. Greyed with the reason when the PC can't take a change.
struct PcLightingSection: View {
    @Binding var selectedPart: PcPart?
    var awake: Bool = true
    @State private var error: String?
    @State private var brightness: Double = 100
    @State private var speed: Double = 5
    @State private var color: Color = .white
    @State private var naming = false
    @State private var lookName = ""

    private var store: PcStore { .shared }
    private static let swatches = ["#ffffff", "#ff3b30", "#ff9f0a", "#ffd60a", "#30d158", "#22d3ee", "#0a84ff", "#bf5af2"]

    private var current: PcPartLight? { store.state?.light(selectedPart ?? .top) }

    var body: some View {
        JcSectionLabel("Lighting")
        VStack(alignment: .leading, spacing: 12) { content }
    }

    @ViewBuilder private var content: some View {
        switch store.availability(awake: awake) {
        case .unavailable(let why):
            JcCard { unavailable(why) }
            if store.isMapped { setupRow }
        case .setUp:
            JcCard(padding: 0) {
                NavigationLink { PcLightingSetupPage() } label: {
                    JcRow(symbol: "wand.and.stars", title: "Set up lighting",
                          subtitle: "Jarvis installs OpenRGB on the PC, then you tap each part as it lights up", last: true)
                }
                .buttonStyle(.plain)
            }
        case .live:
            if let state = store.state {
                controls(state)
                setupRow
            }
        }
    }

    /// Re-run setup or calibrate again (after moving a fan, say).
    private var setupRow: some View {
        JcCard(padding: 0) {
            NavigationLink { PcLightingSetupPage() } label: {
                JcRow(symbol: "slider.horizontal.3", title: "Setup & calibration",
                      subtitle: "Re-run setup steps or show Jarvis each part again", last: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func unavailable(_ why: String) -> some View {
        Label(why, systemImage: "moon.zzz").font(.subheadline).foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func controls(_ state: PcLightingState) -> some View {
        JcCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Lights", isOn: Binding(get: { state.on }, set: { on in change { await store.set(part: nil, on: on) } }))
                    .font(.headline)
                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(JcTheme.muted)
                    Slider(value: $brightness, in: 0...100, step: 1) { editing in
                        if !editing { change { await store.set(part: nil, brightness: Int(brightness)) } }
                    }
                    Text("\(Int(brightness))%").font(.subheadline.monospacedDigit()).foregroundStyle(JcTheme.muted)
                }
                partChips
                if let part = selectedPart, let host = store.sharesWith(part) {
                    Text("\(part.label) share lights with \(host.label.lowercased()) — changing one changes both.")
                        .font(.footnote).foregroundStyle(JcTheme.muted)
                }
                swatchRow
                effectGrid
                if let effect = current.flatMap({ PcEffect(rawValue: $0.effect) }), effect.animated {
                    HStack(spacing: 10) {
                        Image(systemName: "tortoise").foregroundStyle(JcTheme.muted)
                        Slider(value: $speed, in: 1...10, step: 1) { editing in
                            if !editing { change { await store.set(part: selectedPart, speed: Int(speed)) } }
                        }
                        Image(systemName: "hare").foregroundStyle(JcTheme.muted)
                    }
                }
                if store.pausedForGame {
                    Label("Effects are paused while you play", systemImage: "gamecontroller").font(.footnote).foregroundStyle(JcTheme.muted)
                }
                if let err = error ?? store.engineError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(JcTheme.danger)
                }
            }
        }
        .onAppear { brightness = Double(state.brightness); speed = Double(current?.speed ?? 5) }
        .onChange(of: state.brightness) { brightness = Double(state.brightness) }
        looksCard
    }

    private var partChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: selectedPart == nil) { selectedPart = nil }
                    .padding(.leading, 1)
                ForEach(PcPart.allCases) { part in
                    chip(part.label, selected: selectedPart == part, dimmed: store.isMissing(part)) { selectedPart = part }
                        .disabled(store.isMissing(part))
                        .accessibilityHint(store.isMissing(part) ? "No lights mapped for this part" : "")
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? JcAccent.onColor : (dimmed ? JcTheme.muted : JcTheme.text))
                .background(selected ? JcAccent.color : JcButton.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var swatchRow: some View {
        HStack(spacing: 10) {
            ForEach(Self.swatches, id: \.self) { hex in
                Button { change { await store.set(part: selectedPart, color: hex) } } label: {
                    Circle().fill(Color(hexString: hex)).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.white, lineWidth: current?.color == hex ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(hex)")
            }
            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                .onChange(of: color) { change { await store.set(part: selectedPart, color: color.hexRGB) } }
        }
    }

    private var effectGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(PcEffect.allCases) { effect in
                let on = current?.effect == effect.rawValue
                Button { change { await store.set(part: selectedPart, effect: effect) } } label: {
                    Text(effect.label).font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(JcTheme.text)
                        .background(on ? JcButton.selectedFill : JcButton.fill,
                                    in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var looksCard: some View {
        JcCard(padding: 0) {
            ForEach(store.looks) { look in
                JcRow(symbol: "paintpalette", title: look.name, subtitle: "\(look.brightness)%") {
                    change { await store.applyLook(look.name) }
                }
                .contextMenu { Button("Delete", role: .destructive) { change { await store.deleteLook(look.name) } } }
            }
            JcRow(symbol: "plus", title: "Save this look…", last: true) { naming = true }
        }
        .alert("Name this look", isPresented: $naming) {
            TextField("Gaming", text: $lookName)
            Button("Save") { let n = lookName; lookName = ""; change { await store.saveLook(n) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func change(_ op: @escaping () async -> String?) {
        Task { error = await op() }
    }
}

/// The screen's one main action: white fill, black label (his black-and-white rule).
struct PcPrimaryLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(JcAccent.onColor)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous), prominent: true)
    }
}

extension Color {
    init(hexString: String) {
        let v = PcEffects.hex(hexString)
        self.init(red: v.x, green: v.y, blue: v.z)
    }

    /// #rrggbb of this colour (sRGB).
    var hexRGB: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func h(_ x: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, x)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b)
    }
}

/// Setting up lighting on the PC, step by step (Jarvis runs each on the PC; Face ID where it installs).
struct PcLightingSetupPage: View {
    @State private var running: String?
    private var store: PcStore { .shared }
    private static let steps: [(String, String)] = [
        ("openrgb", "Install OpenRGB"), ("signalrgb", "Close SignalRGB"), ("driver", "Sensor driver"),
        ("detect", "Find the lights"), ("cost", "Check games aren't slowed"), ("calibrate", "Show Jarvis each part"),
    ]

    var body: some View {
        ScrollView {
            JcPageColumn {
              VStack(alignment: .leading, spacing: 16) {
                Text("Jarvis sets the PC up for you. Installing asks for Face ID here and Windows' OK on the PC; nothing runs while you're in a game.")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                JcCard(padding: 0) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, item in
                        let step = store.setup[item.0]
                        if item.0 == "calibrate" {
                            NavigationLink { PcCalibrationPage() } label: {
                                JcRow(symbol: icon(step), title: item.1, subtitle: step?.detail ?? "Tap each fan as it lights up",
                                      last: i == Self.steps.count - 1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            JcRow(symbol: icon(step), title: item.1,
                                  subtitle: running == item.0 ? "Working…" : (step?.detail ?? "Not run yet"),
                                  last: i == Self.steps.count - 1) {
                                run(item.0)
                            }
                        }
                    }
                }
                Button { runAll() } label: { PcPrimaryLabel(text: running == nil ? "Run setup" : "Working…") }
                    .buttonStyle(.plain)
                    .disabled(running != nil)
              }
            }
        }
        .jcPageChrome("Set up lighting")
    }

    private func icon(_ step: PcSetupStep?) -> String {
        switch step?.state {
        case "done": "checkmark.circle.fill"
        case "skipped": "minus.circle"
        case "failed": "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private func run(_ id: String) {
        guard running == nil else { return }
        running = id
        Task { _ = await store.runSetup(id); running = nil }
    }

    private func runAll() {
        guard running == nil else { return }
        Task {
            for (id, _) in Self.steps where id != "calibrate" {
                if store.setup[id]?.state == "done" || store.setup[id]?.state == "skipped" { continue }
                running = id
                let result = await store.runSetup(id)
                if result?.state == "failed" { break }
            }
            running = nil
        }
    }
}
