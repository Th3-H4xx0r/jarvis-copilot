import SwiftUI

/// Climate, after Tesla's: the car glides overhead and its roof slices away to the cabin; the
/// windscreen and rear window glow when their defrost is on (tap them to switch it). Below, the
/// temperature, custom climate and defrost — drafts until Save, applied at the next remote start.
struct CarClimateScreen: View {
    @ObservedObject var store: ToyotaStore
    @ObservedObject var stage: CarStage
    @State private var draft: ToyotaCar.Climate?
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @State private var arrived = false

    private var climate: ToyotaCar.Climate? { draft ?? store.car?.climate }
    private var dirty: Bool { draft != nil && draft != store.car?.climate }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CarStageView(stage: stage, at: .cabin) { withAnimation(.easeOut(duration: 0.35)) { arrived = true } }
                if let climate {
                    CarTopOverlay(stage: stage, at: .cabin) { place, marks in
                        if climate.defrostFront != nil {
                            DefrostSpot(on: climate.defrostFront == true, front: true) { toggle(\.defrostFront) }
                                .position(place(marks.windscreen))
                        }
                        if climate.defrostRear != nil {
                            DefrostSpot(on: climate.defrostRear == true, front: false) { toggle(\.defrostRear) }
                                .position(place(marks.rearWindow))
                        }
                    }
                    .opacity(arrived ? 1 : 0)
                    .disabled(!store.isSignedIn || saving)
                }
            }
            .frame(maxHeight: .infinity)
            panel
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Climate")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 18) {
            if let c = climate {
                if let temp = c.temp { temperature(temp, c) }
                HStack(spacing: 10) {
                    if c.custom != nil {
                        toggleTile("power", title: "Climate", on: c.custom == true, tint: JcTheme.accent) { toggle(\.custom) }
                    }
                    if c.defrostFront != nil {
                        toggleTile("windshield.front.and.heat.waves", title: "Front", on: c.defrostFront == true,
                                   tint: JcTheme.amber) { toggle(\.defrostFront) }
                    }
                    if c.defrostRear != nil {
                        toggleTile("windshield.rear.and.heat.waves", title: "Rear", on: c.defrostRear == true,
                                   tint: JcTheme.amber) { toggle(\.defrostRear) }
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.danger).multilineTextAlignment(.center)
                }
                if dirty || saving {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text("Save").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.jcGlass(full: true))
                    .disabled(saving)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text(saved ? "Saved — used at the next remote start" : "Used when you remote start the car")
                        .font(.caption)
                        .foregroundStyle(saved ? JcTheme.success : .secondary)
                }
            } else {
                Text(store.account?.blockedReason ?? "Your car doesn't report remote-start climate settings.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: dirty)
        .disabled(!store.isSignedIn || saving)
    }

    /// ‹ 68° › on its own row, centred — nothing squeezes the number.
    private func temperature(_ temp: Double, _ c: ToyotaCar.Climate) -> some View {
        HStack(spacing: 26) {
            stepButton("chevron.left", enabled: temp > c.min) { step(-1, c) }
            VStack(spacing: 2) {
                Text("\(WearableControl.format(temp))°")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: temp))
                Text(c.unit.contains("C") ? "Cabin · Celsius" : "Cabin · Fahrenheit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Temperature")
            .accessibilityValue("\(WearableControl.format(temp)) degrees")
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1, c)
            }
            stepButton("chevron.right", enabled: temp < c.max) { step(1, c) }
        }
        .frame(maxWidth: .infinity)
    }

    /// A square-ish glass button that switches one setting: icon over its name, lit in `tint` when on.
    private func toggleTile(_ symbol: String, title: String, on: Bool, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                JcIcon(symbol, size: 20)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(on ? tint : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                           tint: on ? tint.opacity(0.25) : .clear)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Climate" ? "Custom climate" : "\(title) defrost")
        .accessibilityValue(on ? "On" : "Off")
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JcIcon(symbol, size: 18)
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(width: 44, height: 44)
                .jcLiquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHidden(true)
    }

    private func step(_ direction: Double, _ c: ToyotaCar.Climate) {
        let step = c.step > 0 ? c.step : 1
        update { climate in
            let next = (climate.temp ?? c.min) + direction * step
            climate.temp = WearableControl.snap(next, range: c.min...max(c.max, c.min), step: step)
        }
    }

    private func toggle(_ key: WritableKeyPath<ToyotaCar.Climate, Bool?>) {
        update { $0[keyPath: key] = !($0[keyPath: key] ?? false) }
    }

    /// Changes the draft, starting from the car's saved climate.
    private func update(_ change: (inout ToyotaCar.Climate) -> Void) {
        guard var next = climate else { return }
        change(&next)
        withAnimation(.easeInOut(duration: 0.2)) { draft = next }
        error = nil
        saved = false
    }

    private func save() {
        guard let draft else { return }
        saving = true
        Task {
            do {
                try await store.saveClimate(draft)
                self.draft = nil
                saved = true
            } catch {
                self.error = apiErrorMessage(error)
            }
            saving = false
        }
    }
}

/// The windscreen's (or rear window's) defrost on the cabin view: a warm glow when on.
struct DefrostSpot: View {
    let on: Bool
    let front: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if on {
                    Capsule()
                        .fill(RadialGradient(colors: [JcTheme.amber.opacity(0.55), JcTheme.amber.opacity(0)],
                                             center: .center, startRadius: 4, endRadius: 70))
                        .frame(width: 150, height: 54)
                        .blur(radius: 6)
                }
                JcIcon(front ? "windshield.front.and.heat.waves" : "windshield.rear.and.heat.waves", size: 18)
                    .foregroundStyle(on ? JcTheme.amber : Color.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .jcLiquidGlass(in: Circle(), tint: on ? JcTheme.amber.opacity(0.3) : .clear)
            }
            .contentShape(Circle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: on)
        .accessibilityLabel(front ? "Front defrost" : "Rear defrost")
        .accessibilityValue(on ? "On" : "Off")
    }
}
