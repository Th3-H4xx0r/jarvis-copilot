import Charts
import SwiftUI

/// One stat on a ring card: its name and the day's value, nil when the ring has none.
struct RingStat {
    let label: String
    let value: String?
}

/// A ring metric card: the headline stat big and bold at the top left, the rest
/// small beneath it, and a chart you can scrub. While a finger is on the chart the
/// headline becomes the reading at that moment, captioned with when it was; letting
/// go puts the day's number back.
/// A second headline number, shown at the card's top right in its own colour.
struct RingBadge: Equatable {
    var label: String
    var value: String
    var caption: String?
    var tint: Color
}

struct RingMetricCard<X: Plottable & Equatable, ChartBody: View>: View {
    let title: String
    let headline: RingStat
    var details: [RingStat] = []
    /// A second number for the top-right corner — a score the card is judged by,
    /// set apart from the headline by colour so the two never read as one value.
    var badge: RingBadge?
    /// A Measure button for a reading taken now; while it runs, the headline
    /// is the ring's live number.
    var measure: RingCardMeasure?
    /// Shown in place of the chart when there is nothing to plot.
    var emptyText: String?
    /// The reading under the finger, or nil for a gap.
    let readout: (X) -> RingScrubReadout?
    /// The chart, given the scrubbed position to mark and the binding to scrub with.
    @ViewBuilder let chart: (_ selected: X?, _ selection: Binding<X?>) -> ChartBody

    @State private var selection: X?

    private var scrubbed: RingScrubReadout? {
        guard let selection else { return nil }
        return readout(selection) ?? RingScrubReadout(value: "—", caption: "No reading here")
    }

    var body: some View {
        CardGroup(title) {
            VStack(alignment: .leading, spacing: 14) {
                headlineBlock
                if !shownDetails.isEmpty { detailGrid }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            RowDivider()
            if let emptyText {
                Row { Text(emptyText).font(.subheadline).foregroundStyle(.secondary) }
            } else {
                chart(selection, $selection)
                    .padding(14)
                    .accessibilityHint("Drag across the chart to see the reading at each time")
            }
        }
        .sensoryFeedback(.selection, trigger: scrubbed)
    }

    /// What the headline says right now: the scrubbed reading, a measurement
    /// in progress or just finished, or the day's number.
    private var shown: (label: String, value: String, highlighted: Bool, placeholder: Bool) {
        if let scrubbed { return (scrubbed.caption, scrubbed.value, true, false) }
        switch measure?.state {
        case .measuring(let live)?: return ("Measuring…", live ?? "--", true, live == nil)
        case .result(let value)?: return ("Just now", value, true, false)
        case .failed(let why)?: return (why, headline.value ?? "—", false, false)
        default: return (headline.label, headline.value ?? "—", false, false)
        }
    }

    private var headlineBlock: some View {
        let shown = shown
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(shown.highlighted ? AnyShapeStyle(JcTheme.accent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                // The same rolling digits whether a finger is scrubbing or the
                // ring is sending: "--" while the sensor warms up.
                Text(shown.value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(shown.placeholder ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            .animation(.snappy(duration: 0.18), value: scrubbed)
            .animation(.snappy(duration: 0.25), value: shown.value)

            if let measure {
                Spacer(minLength: 12)
                RingMeasureButton(measure: measure)
            } else if let badge {
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(badge.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(badge.value)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(badge.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let caption = badge.caption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Only the stats the ring actually has: a small grid of dashes was noise.
    private var shownDetails: [RingStat] { details.filter { $0.value != nil } }

    private var detailGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                  alignment: .leading, spacing: 10) {
            ForEach(shownDetails.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    Text(shownDetails[index].label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(shownDetails[index].value ?? "—")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }
}

/// Measure, or Stop while the reading runs: a small glass capsule in the
/// card's top corner, where Apple puts a card's one action.
struct RingMeasureButton: View {
    let measure: RingCardMeasure

    var body: some View {
        if case .measuring = measure.state {
            Button("Stop", action: measure.stop)
                .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                .accessibilityLabel("Stop measuring")
        } else {
            Button("Measure", action: measure.start)
                .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                .disabled(!measure.enabled)
                .accessibilityHint("Takes a reading with your ring now")
        }
    }
}

/// The scrub marker every ring chart draws at the selected position, in the scale
/// chart's style.
struct RingScrubRule<X: Plottable>: ChartContent {
    let x: X

    var body: some ChartContent {
        RuleMark(x: .value("Selected", x))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.white.opacity(0.55))
    }
}
