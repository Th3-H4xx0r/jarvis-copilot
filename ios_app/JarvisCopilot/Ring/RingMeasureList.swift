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
        .scrollReveal()
    }

    private func row(_ item: Item) -> some View {
        Row(minHeight: 58) {
            HStack(spacing: 12) {
                RingMetricSymbol(name: item.type.icon, tint: item.type.tint, pulsing: isMeasuring(item))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.type.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if case .measuring(let live) = item.state {
                        // "--" while the sensor warms up, then each number the
                        // ring sends rolls in, in the metric's colour.
                        Text(live ?? "--")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(live == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(item.type.tint))
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: live)
                    } else {
                        Text(subtitle(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if let control = item.control { RingMeasureButton(measure: control) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func isMeasuring(_ item: Item) -> Bool {
        if case .measuring = item.state { return true }
        return false
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
