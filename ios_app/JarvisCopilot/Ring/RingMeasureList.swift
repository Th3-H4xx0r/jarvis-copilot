import SwiftUI

/// The ring screen's Measure card: one row per reading the ring can take on
/// demand, with the last one it took and Measure — or, while it runs, the
/// ring's live number and Stop.
struct RingMeasureList: View {
    struct Item {
        let label: String
        let icon: String
        let tint: Color
        let state: RingCardMeasure.State
        let last: (text: String, time: Date)?
        let control: RingCardMeasure?

        init(type: RingMeasurementType, state: RingCardMeasure.State, last: (text: String, time: Date)?,
             control: RingCardMeasure?) {
            self.init(label: type.label, icon: type.icon, tint: type.tint, state: state, last: last, control: control)
        }

        /// Any wearable's reading (the band's has its own types).
        init(label: String, icon: String, tint: Color, state: RingCardMeasure.State,
             last: (text: String, time: Date)?, control: RingCardMeasure?) {
            self.label = label
            self.icon = icon
            self.tint = tint
            self.state = state
            self.last = last
            self.control = control
        }
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
                RingMetricSymbol(name: item.icon, tint: item.tint, pulsing: isMeasuring(item))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if case .measuring(let live) = item.state {
                        // "--" while the sensor warms up, then each number the
                        // ring sends rolls in, in the metric's colour.
                        Text(live ?? "--")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(live == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(item.tint))
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.25), value: live)
                            .geometryGroup()
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
