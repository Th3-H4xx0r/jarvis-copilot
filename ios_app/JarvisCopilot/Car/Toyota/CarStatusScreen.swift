import SwiftUI

/// Status: the car from straight above with each tyre's pressure beside its wheel and anything open
/// marked on the car, then the details.
struct CarStatusScreen: View {
    @ObservedObject var store: ToyotaStore
    @ObservedObject var stage: CarStage
    @State private var arrived = false

    private var car: ToyotaCar? { store.car }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack {
                    CarStageView(stage: stage, at: .top) { withAnimation(.easeOut(duration: 0.35)) { arrived = true } }
                    CarTopOverlay(stage: stage, at: .top) { place, marks in
                        if let tires = car?.tires { tireLabels(tires, place: place, marks: marks) }
                        openMarkers(place: place, marks: marks)
                    }
                    .opacity(arrived ? 1 : 0)
                }
                .frame(height: 420)
                if let updated = car?.tires?.updatedAt {
                    Text("Tyres updated \(updated, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardGroup {
                    let rows = statusRows
                    if rows.isEmpty {
                        Row { Text(store.account?.blockedReason ?? "Nothing reported yet.").foregroundStyle(.secondary) }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 60) }
                        ToyotaStatusRow(icon: row.icon, title: row.title, value: row.value, ok: row.ok)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tireLabels(_ tires: ToyotaCar.Tires, place: @escaping (SIMD3<Float>) -> CGPoint, marks: Landmarks) -> some View {
        let wheels: [(String, Double?, String)] = [("fl", tires.fl, "Front Driver"), ("fr", tires.fr, "Front Passenger"),
                                                   ("rl", tires.rl, "Rear Driver"), ("rr", tires.rr, "Rear Passenger")]
        ForEach(wheels, id: \.0) { key, psi, wheel in
            if let at = marks.wheels[key] {
                let point = place(at)
                let left = key.hasSuffix("l")
                TirePressureLabel(psi: psi, unit: tires.unit, warned: tires.warnings.contains(wheel), alignLeft: !left)
                    .position(x: point.x + (left ? -74 : 74), y: point.y)
                    .accessibilityLabel("\(wheel) tyre")
            }
        }
    }

    /// An amber tag on each open door, the trunk or the hood.
    @ViewBuilder
    private func openMarkers(place: @escaping (SIMD3<Float>) -> CGPoint, marks: Landmarks) -> some View {
        let open = Set((car?.doors?.open ?? []) + (car?.trunk?.open ?? []) + (car?.hood?.open ?? []))
        let half = marks.length / 2, z = marks.centreZ
        let spots: [(String, SIMD3<Float>)] = [
            ("Front Driver", SIMD3(0.9, 1, z + half * 0.18)), ("Front Passenger", SIMD3(-0.9, 1, z + half * 0.18)),
            ("Rear Driver", SIMD3(0.9, 1, z - half * 0.22)), ("Rear Passenger", SIMD3(-0.9, 1, z - half * 0.22)),
            ("Trunk", SIMD3(0, 1, z - half * 0.82)), ("Hood", SIMD3(0, 1, z + half * 0.7)),
        ]
        ForEach(spots.filter { open.contains($0.0) }, id: \.0) { name, at in
            Text("Open")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(JcTheme.amber, in: Capsule())
                .position(place(at))
                .accessibilityLabel("\(name) open")
        }
    }

    private struct Line {
        let icon: String, title: String, value: String, ok: Bool
    }

    private var statusRows: [Line] {
        guard let car else { return [] }
        var rows: [Line] = []
        if let tires = car.tires {
            rows.append(Line(icon: "tirepressure", title: "Tyre Pressure",
                             value: tires.warnings.isEmpty ? "Good" : "Check " + tires.warnings.joined(separator: ", ").lowercased(),
                             ok: tires.warnings.isEmpty))
        }
        if let doors = car.doors {
            let lock = doors.locked.map { $0 ? "Locked" : "Unlocked" }
            let open = doors.open.isEmpty ? nil : "Open: " + doors.open.joined(separator: ", ").lowercased()
            let value = [lock, open].compactMap { $0 }.joined(separator: " · ")
            rows.append(Line(icon: doors.locked == false ? "lock.open.fill" : "lock.fill", title: "Doors",
                             value: value.isEmpty ? "Closed" : value, ok: doors.locked != false && doors.open.isEmpty))
        }
        if let windows = car.windows { rows.append(opening("window.vertical.closed", "Windows", windows)) }
        if let trunk = car.trunk {
            if let locked = trunk.locked, trunk.open.isEmpty {
                rows.append(Line(icon: "car.side.rear.open", title: "Trunk", value: locked ? "Closed · locked" : "Closed · unlocked", ok: locked))
            } else {
                rows.append(opening("car.side.rear.open", "Trunk", trunk))
            }
        }
        if let hood = car.hood { rows.append(opening("car.side.front.open", "Hood", hood)) }
        if let roof = car.moonroof { rows.append(opening("sun.max", "Moonroof", roof)) }
        return rows
    }

    private func opening(_ icon: String, _ title: String, _ o: ToyotaCar.Opening) -> Line {
        Line(icon: icon, title: title,
             value: o.open.isEmpty ? "Closed" : (o.open == [title] ? "Open" : "Open: " + o.open.joined(separator: ", ").lowercased()),
             ok: o.open.isEmpty)
    }
}

/// A tyre's pressure beside its wheel on the top view.
struct TirePressureLabel: View {
    let psi: Double?
    let unit: String
    let warned: Bool
    /// The left-hand labels read toward the car (right-aligned), the right-hand ones away from it.
    let alignLeft: Bool

    var body: some View {
        VStack(alignment: alignLeft ? .leading : .trailing, spacing: 0) {
            Text(psi.map { WearableControl.format($0.rounded()) } ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(warned ? "\(unit) · low" : unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(warned ? JcTheme.amber : .secondary)
        }
        .foregroundStyle(warned ? JcTheme.amber : Color.primary)
        .frame(width: 84, alignment: alignLeft ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// A status line: icon with a ✓ or ! badge, title, value, and an optional note under it.
struct ToyotaStatusRow: View {
    let icon: String
    let title: String
    let value: String
    let ok: Bool
    var note: String?

    var body: some View {
        Row(minHeight: 60) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    JcIcon(icon, size: 18)
                        .foregroundStyle(JcTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.06), in: Circle())
                    JcIcon(ok ? "checkmark" : "exclamationmark", size: 9)
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(ok ? JcTheme.success : JcTheme.amber, in: Circle())
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(value).font(.subheadline).foregroundStyle(ok ? Color.secondary : JcTheme.amber)
                    if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
