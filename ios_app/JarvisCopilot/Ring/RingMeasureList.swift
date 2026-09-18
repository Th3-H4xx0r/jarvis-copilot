import SwiftUI

/// The ring screen's Measure card: one row per reading the ring can take on
/// demand, with the last one it took and Measure — or, while it runs, the
/// ring's live number and Stop.
struct RingMeasureList: View {
    struct Item {
        let type: RingMeasurementType
        let state: RingCardMeasure.State
        let last: (text: String, time: Date)?
        let control: RingCardMeasure?
    }

    let items: [Item]

    var body: some View {
        CardGroup("Measure") {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { RowDivider() }
                row(item)
            }
        }
    }

    private func row(_ item: Item) -> some View {
        Row(minHeight: 58) {
            HStack(spacing: 12) {
                JcIcon(item.type.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(item.type.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.type.label).font(.body.weight(.medium))
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if case .measuring(let live) = item.state {
                    // "--" while the sensor warms up, then each number the ring
                    // sends rolls in.
                    Text(live ?? "--")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(live == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(item.type.tint))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: live)
                }
                if let control = item.control { RingMeasureButton(measure: control) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func subtitle(_ item: Item) -> String {
        switch item.state {
        case .measuring: return "Measuring…"
        case .result(let value): return "\(value) · just now"
        case .failed(let why): return why
        case .idle:
            guard let last = item.last else { return "No reading yet" }
            return "\(last.text) · \(last.time.formatted(.relative(presentation: .named)))"
        }
    }
}
