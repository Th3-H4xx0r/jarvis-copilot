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

/// A metric's symbol, in its colour: always on its card, pulsing while the
/// ring measures it.
struct RingSymbol: Equatable {
    let name: String
    let tint: Color
}

struct RingMetricCard<X: Plottable & Equatable, ChartBody: View>: View {
    let title: String
    var symbol: RingSymbol?
    let headline: RingStat
    var details: [RingStat] = []
    /// A second number for the top-right corner — a score the card is judged by,
    /// set apart from the headline by colour so the two never read as one value.
    var badge: RingBadge?
    /// A Measure button for a reading taken now; while it runs, the headline
    /// is the ring's live number.
    var measure: RingCardMeasure?
    /// A goal the headline counts toward (steps), drawn as a ring in the corner.
    var goal: (value: Int, target: Int)?
    /// Opens this metric's history; shows "Show all ›" beside the title.
    var showAll: (() -> Void)?
    /// Shown in place of the chart when there is nothing to plot.
    var emptyText: String?
    /// The reading under the finger, or nil for a gap.
    let readout: (X) -> RingScrubReadout?
    /// The chart, given the scrubbed position to mark and the binding to scrub with.
    @ViewBuilder let chart: (_ selected: X?, _ selection: Binding<X?>) -> ChartBody

    @State private var selection: X?
    /// The headline has been seen: any goal ring has filled.
    @State private var revealed = false
    /// The chart has been seen: its line has drawn in, once.
    @State private var chartRevealed = false

    private var scrubbed: RingScrubReadout? {
        guard let selection else { return nil }
        return readout(selection) ?? RingScrubReadout(value: "—", caption: "No reading here")
    }

    var body: some View {
        CardGroup(title) {
            VStack(alignment: .leading, spacing: 14) {
                headlineBlock
                    .onScrolledIntoView { if !revealed { revealed = true } }
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
                    // The line draws in from the left the first time the chart
                    // itself scrolls into view; the card stays put.
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: chartRevealed ? 1 : 0.001, anchor: .leading)
                    }
                    .animation(.easeOut(duration: 0.9), value: chartRevealed)
                    .onScrolledIntoView { if !chartRevealed { chartRevealed = true } }
                    .accessibilityHint("Drag across the chart to see the reading at each time")
            }
            // Inside the card, along its foot: its top corner already holds
            // the goal ring, a score or Measure.
            if let showAll {
                RowDivider()
                ShowAllRow(action: showAll)
            }
        }
        .sensoryFeedback(.selection, trigger: scrubbed)
    }

    private var isMeasuring: Bool {
        if case .measuring = measure?.state { return true }
        return false
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
                HStack(spacing: 6) {
                    if let symbol {
                        RingMetricSymbol(name: symbol.name, tint: symbol.tint, pulsing: isMeasuring, size: 13)
                    }
                    Text(shown.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(shown.highlighted ? AnyShapeStyle(JcTheme.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                // The same rolling digits whether a finger is scrubbing or the
                // ring is sending: "--" while the sensor warms up.
                // Until the card is first seen every digit sits at zero; then
                // they roll up to the value, like an odometer.
                Text(revealed ? shown.value : shown.value.odometerZero)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(shown.placeholder ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            .animation(.snappy(duration: 0.18), value: scrubbed)
            .animation(.snappy(duration: 0.25), value: shown.value)
            .animation(.odometer, value: revealed)

            if let measure {
                Spacer(minLength: 12)
                RingMeasureButton(measure: measure)
            } else if let goal {
                Spacer(minLength: 12)
                RingGoalRing(value: goal.value, goal: goal.target, revealed: revealed)
            } else if let badge {
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(badge.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(revealed ? badge.value : badge.value.odometerZero)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(badge.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                        .animation(.odometer, value: revealed)
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
                    Text(revealed ? shownDetails[index].value ?? "—" : (shownDetails[index].value ?? "—").odometerZero)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                        .animation(.odometer, value: revealed)
                }
            }
        }
    }
}

/// "Show all ›" in a card's free top corner: the way into its history.
struct ShowAllLink: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("Show all")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(JcTheme.accent)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show all history")
    }
}

/// "Show all" as the last row of a card whose corner is taken — the way
/// Apple Health ends a card with Show All Data.
struct ShowAllRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(minHeight: 46) {
                HStack {
                    Text("Show all")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(JcTheme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show all history")
    }
}

/// Measure, or Stop while the reading runs: a small glass capsule in the
/// card's top corner, where Apple puts a card's one action.
struct RingMeasureButton: View {
    let measure: RingCardMeasure

    var body: some View {
        if case .measuring = measure.state {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Button("Stop", action: measure.stop)
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                    .fixedSize()
                    .accessibilityLabel("Stop measuring")
            }
        } else {
            Button("Measure", action: measure.start)
                .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                .fixedSize()
                .disabled(!measure.enabled)
                .accessibilityHint("Takes a reading with your ring now")
        }
    }
}

/// A metric's icon in its colour. While the ring measures that metric it
/// beats — a gentle swell and fade — and with Reduce Motion it only fades.
struct RingMetricSymbol: View {
    let name: String
    let tint: Color
    var pulsing = false
    var size: CGFloat = 17

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let icon = JcIcon(name, size: size).foregroundStyle(tint)
        Group {
            // Its own branch, so the beat starts fresh each time a reading
            // does (an animator whose phases change mid-flight never starts).
            if pulsing {
                icon.phaseAnimator([false, true]) { icon, beat in
                    icon
                        .scaleEffect(beat && !reduceMotion ? 1.22 : 1)
                        .opacity(beat ? 0.5 : 1)
                } animation: { _ in .easeInOut(duration: 0.5) }
            } else {
                icon
            }
        }
        .accessibilityHidden(true)
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
