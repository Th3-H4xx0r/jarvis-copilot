import SwiftUI

/// Status: the four tyre pressures around a top-down car, then doors, windows, trunk and more.
struct CarStatusTab: View {
    let car: ToyotaCar?

    var body: some View {
        VStack(spacing: 14) {
            if let tires = car?.tires { TireDiagram(tires: tires) }
            CardGroup {
                let rows = statusRows
                if rows.isEmpty {
                    Row { Text("Nothing reported yet.").foregroundStyle(.secondary) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 60) }
                    ToyotaStatusRow(icon: row.icon, title: row.title, value: row.value, ok: row.ok, note: row.note)
                }
            }
        }
    }

    private struct Line {
        let icon: String, title: String, value: String, ok: Bool
        var note: String? = nil
    }

    private var statusRows: [Line] {
        guard let car else { return [] }
        var rows: [Line] = []
        if let tires = car.tires {
            rows.append(Line(icon: "tirepressure", title: "Tire Pressure",
                             value: tires.warnings.isEmpty ? "Good" : "Check " + tires.warnings.joined(separator: ", ").lowercased(),
                             ok: tires.warnings.isEmpty,
                             note: tires.updatedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" }))
        }
        if let doors = car.doors {
            let lock = doors.locked.map { $0 ? "Locked" : "Unlocked" }
            let open = doors.open.isEmpty ? nil : "Open: " + doors.open.joined(separator: ", ").lowercased()
            rows.append(Line(icon: doors.locked == false ? "lock.open.fill" : "lock.fill", title: "Doors",
                             value: [lock, open].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Closed",
                             ok: doors.locked != false && doors.open.isEmpty))
        }
        if let windows = car.windows { rows.append(opening("window.vertical.closed", "Windows", windows)) }
        if let trunk = car.trunk {
            var line = opening("car.side.rear.open", "Trunk", trunk)
            if let locked = trunk.locked, trunk.open.isEmpty {
                line = Line(icon: line.icon, title: "Trunk", value: locked ? "Closed · locked" : "Closed · unlocked", ok: locked)
            }
            rows.append(line)
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
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

/// Top-down car with the pressure at each wheel (front at the top; driver on the left).
struct TireDiagram: View {
    let tires: ToyotaCar.Tires

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 70) { value(tires.fl, "Front Driver"); value(tires.rl, "Rear Driver") }
            CarOutline()
                .stroke(.white.opacity(0.55), lineWidth: 1.5)
                .background(CarOutline().fill(.white.opacity(0.05)))
                .frame(width: 92, height: 178)
            VStack(spacing: 70) { value(tires.fr, "Front Passenger"); value(tires.rr, "Rear Passenger") }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func value(_ psi: Double?, _ wheel: String) -> some View {
        let warned = tires.warnings.contains(wheel)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(psi.map { WearableControl.format($0.rounded()) } ?? "—")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(tires.unit).font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(warned ? JcTheme.amber : Color.primary)
        .frame(width: 84)
        .accessibilityLabel("\(wheel) tire")
        .accessibilityValue(psi.map { "\(Int($0.rounded())) \(tires.unit)" } ?? "unknown")
    }
}

/// A simple sedan seen from above: body, windscreen and rear window.
struct CarOutline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r.insetBy(dx: 4, dy: 2), cornerRadius: r.width * 0.32)
        let w = r.width, h = r.height
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.2, y: r.minY + h * 0.27, width: w * 0.6, height: h * 0.13),
                         cornerSize: CGSize(width: 8, height: 8))
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.22, y: r.minY + h * 0.68, width: w * 0.56, height: h * 0.09),
                         cornerSize: CGSize(width: 7, height: 7))
        return p
    }
}
