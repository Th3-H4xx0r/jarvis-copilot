import SwiftUI

/// The Car page's sheets — presented by the page itself, outside its pull-to-refresh, so pulling
/// down inside one never wakes the car.
enum CarSheet: String, Identifiable {
    case signIn
    var id: String { rawValue }
}

/// The top of the Car page, after Tesla's app: where the car is and whether it's locked, the car
/// itself, the range, four quick actions, then a row per area that opens its own screen (the car
/// gliding overhead in each).
struct CarToyotaHome: View {
    @ObservedObject var store: ToyotaStore
    @ObservedObject var stage: CarStage
    @ObservedObject var presence: CarPresence
    let profile: CarProfile

    var body: some View {
        VStack(spacing: 16) {
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            CarStageView(stage: stage, at: .hero, turnable: true, lit: presence.inCar)
                .frame(height: 230)
            range
            if let reason = store.account?.blockedReason ?? store.problem {
                Label(reason, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }
            CarQuickActions(store: store, stage: stage)
                .padding(.horizontal, 12)
            menu
        }
    }

    private var statusText: String {
        var parts = [presence.inCar ? "With you" : "Parked"]
        if store.car?.running == true { parts.append("Running") }
        if let locked = store.car?.doors?.locked { parts.append(locked ? "Locked" : "Unlocked") }
        return parts.joined(separator: " · ")
    }

    private var range: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(store.car?.rangeMi.map { "\(Int($0))" } ?? "—")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("mi").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            if let fuel = store.car?.fuelPct {
                FuelBar(fraction: fuel / 100)
                    .frame(width: 150, height: 5)
            }
            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        var parts = ["\(profile.year) \(profile.model) \(profile.trim)"]
        if let odometer = store.car?.odometerMi { parts.append("\(Int(odometer).formatted()) mi") }
        if let at = store.car?.updatedAt { parts.append("Updated " + at.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var menu: some View {
        CardGroup {
            row("slider.horizontal.3", "Controls", "Lock, start, trunk, lights, horn, hazards") {
                CarControlsScreen(store: store, stage: stage)
            }
            Divider().padding(.leading, 60)
            row("fan.fill", "Climate", climateSummary) { CarClimateScreen(store: store, stage: stage) }
            Divider().padding(.leading, 60)
            row("car.side", "Status", statusSummary) { CarStatusScreen(store: store, stage: stage) }
            Divider().padding(.leading, 60)
            row("mappin.and.ellipse", "Location", locationSummary) { CarLocationScreen(car: store.car) }
            Divider().padding(.leading, 60)
            row("heart.text.square.fill", "Health", healthSummary) { CarHealthScreen(car: store.car) }
        }
    }

    private func row<Destination: View>(_ icon: String, _ title: String, _ detail: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            Row(minHeight: 58) {
                HStack(spacing: 14) {
                    JcIcon(icon, size: 17)
                        .foregroundStyle(JcTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(JcTheme.accent.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    JcIcon("chevron.right", size: 13).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var climateSummary: String {
        guard let c = store.car?.climate else { return "Not reported yet" }
        let temp = c.temp.map { "\(WearableControl.format($0))\(c.unit)" } ?? "—"
        let defrost = [c.defrostFront == true ? "front" : nil, c.defrostRear == true ? "rear" : nil].compactMap { $0 }
        return temp + " · " + (defrost.isEmpty ? "Defrost off" : "Defrost " + defrost.joined(separator: " + "))
    }

    private var statusSummary: String {
        guard let car = store.car else { return "Not reported yet" }
        var parts: [String] = []
        if let locked = car.doors?.locked { parts.append(locked ? "Locked" : "Unlocked") }
        let open = (car.doors?.open ?? []) + (car.trunk?.open ?? []) + (car.hood?.open ?? []) + (car.windows?.open.isEmpty == false ? ["Windows"] : [])
        if !open.isEmpty { parts.append(open.joined(separator: ", ") + " open") }
        if let tires = car.tires { parts.append(tires.warnings.isEmpty ? "Tyres good" : "Check tyres") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var locationSummary: String {
        guard let location = store.car?.location else { return "No location yet" }
        guard let at = location.at else { return "Last parked" }
        return "Parked " + at.formatted(.relative(presentation: .named))
    }

    private var healthSummary: String {
        let items = store.car?.health ?? []
        if items.isEmpty { return "Nothing reported yet" }
        let bad = items.filter { !$0.ok }.count
        return bad == 0 ? "All good" : "\(bad) need\(bad == 1 ? "s" : "") attention"
    }
}

/// Lock/Unlock (by the car's lock state), Climate, Start/Stop and Trunk — round, like Tesla's.
struct CarQuickActions: View {
    @ObservedObject var store: ToyotaStore
    @ObservedObject var stage: CarStage
    @State private var nudged = false

    private var lockAction: ToyotaCommand { store.car?.doors?.locked == true ? .unlock : .lock }
    private var startAction: ToyotaCommand { store.car?.running == true ? .stop : .start }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                button(lockAction, pair: [.lock, .unlock])
                NavigationLink {
                    CarClimateScreen(store: store, stage: stage)
                } label: {
                    ToyotaRoundFace(symbol: "fan.fill", title: "Climate", caption: " ",
                                    tint: store.car?.climate?.custom == true ? JcTheme.accent : .white)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                button(startAction)
                button(.trunkUnlock, title: "Trunk")
            }
            Text(nudged ? "Hold the button to activate" : "Tap and hold to activate")
                .font(.caption)
                .foregroundStyle(nudged ? JcTheme.amber : Color.secondary.opacity(0.7))
                .animation(.easeInOut(duration: 0.2), value: nudged)
        }
    }

    /// `pair`: the commands one flipping button stands for (Lock/Unlock), so its spinner and result
    /// stay on it when the car's new state flips it. Climate stays usable signed out (it explains).
    private func button(_ command: ToyotaCommand, title: String? = nil, pair: [ToyotaCommand]? = nil) -> some View {
        let commands = pair ?? [command]
        let busy = commands.contains { store.isBusy($0) }
        return ToyotaRoundButton(command: command, title: title,
                                 available: store.isSignedIn && (store.car?.commands.contains(command) ?? false),
                                 busy: busy,
                                 waiting: store.busy != nil && !busy,
                                 outcome: commands.lazy.compactMap { store.outcome(for: $0) }.first,
                                 onShortTap: nudge,
                                 onHold: { Task { await store.run(command) } })
    }

    private func nudge() {
        nudged = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            nudged = false
        }
    }
}

/// The fuel left, as a thin bar.
struct FuelBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(JcTheme.accent)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
        }
        .accessibilityLabel("Fuel")
        .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100)) percent")
    }
}
