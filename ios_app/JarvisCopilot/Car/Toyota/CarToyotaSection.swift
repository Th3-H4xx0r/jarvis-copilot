import SwiftUI

/// The Car page's Toyota sheets. They're presented by the page itself, outside its pull-to-refresh,
/// so pulling down inside a sheet never wakes the car.
enum CarSheet: String, Identifiable {
    case climate, find, signIn
    var id: String { rawValue }
}

/// The tabs on the Car page, like Toyota's own app.
enum CarToyotaTab: String, CaseIterable, Identifiable {
    case remote, status, health
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remote: return "Remote"
        case .status: return "Status"
        case .health: return "Health"
        }
    }
}

/// The Toyota part of the Car page: range / odometer / last-report pills, then Remote · Status · Health.
struct CarToyotaSection: View {
    @ObservedObject var store: ToyotaStore
    var open: (CarSheet) -> Void
    @AppStorage("car.toyota.tab") private var tab = CarToyotaTab.remote.rawValue

    private var selected: CarToyotaTab { CarToyotaTab(rawValue: tab) ?? .remote }

    var body: some View {
        VStack(spacing: 14) {
            ToyotaPills(car: store.car)
            Picker("Car", selection: $tab) {
                ForEach(CarToyotaTab.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            if let reason = store.account?.blockedReason ?? store.problem {
                Label(reason, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            Group {
                switch selected {
                case .remote:
                    CarRemoteTab(store: store, openClimate: { open(.climate) }, openFind: { open(.find) })
                case .status:
                    CarStatusTab(car: store.car)
                case .health:
                    CarHealthTab(car: store.car)
                }
            }
            .opacity(store.isSignedIn ? 1 : 0.45)
            .disabled(!store.isSignedIn)
        }
    }
}

/// Distance to empty with the fuel bar, the odometer, and how old the car's last report is.
struct ToyotaPills: View {
    let car: ToyotaCar?

    var body: some View {
        HStack(spacing: 8) {
            rangePill
            MetricPill(icon: "gauge.with.needle", label: "Odometer",
                       value: car?.odometerMi.map { "\(Int($0).formatted()) mi" } ?? "—", tint: JcTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if let at = car?.updatedAt {
                Text("Updated \(at, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .offset(y: 18)
            }
        }
        .padding(.bottom, car?.updatedAt == nil ? 0 : 14)
    }

    private var rangePill: some View {
        HStack(spacing: 9) {
            JcIcon("fuelpump.fill", size: 12)
                .foregroundStyle(JcTheme.accent)
                .frame(width: 26, height: 26)
                .background(JcTheme.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(car?.rangeMi.map { "\(Int($0)) mi to empty" } ?? "Range —")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(JcTheme.accent)
                                .frame(width: geo.size.width * min(max((car?.fuelPct ?? 0) / 100, 0), 1))
                        }
                }
                .frame(width: 96, height: 4)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(car?.fuelPct.map { "Fuel \(Int($0)) percent" } ?? "")
    }
}
