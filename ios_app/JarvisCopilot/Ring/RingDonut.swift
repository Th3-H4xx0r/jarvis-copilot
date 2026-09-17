import SwiftUI

/// A ring of shares with its own legend — sleep stages, stress bands.
///
/// Deliberately small: a donut is only worth drawing when the shares add up to
/// something, so an empty set renders nothing rather than an empty circle.
struct RingDonut: View {
    struct Slice: Identifiable, Equatable {
        var label: String
        var value: Double
        var color: Color
        var detail: String = ""

        var id: String { label }
    }

    let slices: [Slice]
    var lineWidth: CGFloat = 10
    var diameter: CGFloat = 64

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        if total > 0 {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    ForEach(Array(offsets.enumerated()), id: \.element.slice.id) { _, item in
                        Circle()
                            .trim(from: item.start, to: item.end)
                            .stroke(item.slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: diameter, height: diameter)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(slices) { slice in
                        HStack(spacing: 6) {
                            Circle().fill(slice.color).frame(width: 6, height: 6)
                            Text(slice.label).font(.caption)
                            Spacer(minLength: 4)
                            Text(percent(slice.value)).font(.caption.weight(.semibold)).monospacedDigit()
                            if !slice.detail.isEmpty {
                                Text(slice.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            // The ring needs air above and below: it sat against the numbers
            // over it and the stage timeline under it.
            .padding(.vertical, 10)
        }
    }

    private var offsets: [(slice: Slice, start: CGFloat, end: CGFloat)] {
        var running: Double = 0
        return slices.compactMap { slice in
            guard slice.value > 0 else { return nil }
            let start = running / total
            running += slice.value
            return (slice, CGFloat(start), CGFloat(running / total))
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value / total * 100).rounded()))%"
    }
}

/// The four bands the ring's own app and Garmin both use for stress.
enum StressBand: String, CaseIterable, Identifiable {
    case relax, normal, medium, high

    var id: String { rawValue }

    var range: ClosedRange<Double> {
        switch self {
        case .relax: return 0...29
        case .normal: return 30...59
        case .medium: return 60...79
        case .high: return 80...100
        }
    }

    var label: String {
        switch self {
        case .relax: return "Relax"
        case .normal: return "Normal"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var color: Color {
        switch self {
        case .relax: return JcTheme.primaryBlue
        case .normal: return JcTheme.accent
        case .medium: return JcTheme.amber
        case .high: return .orange
        }
    }

    static func of(_ value: Double) -> StressBand {
        allCases.first { $0.range.contains(value) } ?? (value > 100 ? .high : .relax)
    }
}

/// How much of a day sat in each stress band.
struct StressBandShare: Identifiable, Equatable {
    var band: StressBand
    var samples: Int
    var minutes: Int
    var percent: Double

    var id: String { band.rawValue }
}

extension StressBand {
    /// Shares of the readings the ring actually took — a zero means "no reading",
    /// so it is not a relaxed minute.
    static func shares(of series: RingSeries?) -> [StressBandShare] {
        guard let series else { return [] }
        let readings = series.values.filter { $0 > 0 }
        guard !readings.isEmpty else { return [] }
        return allCases.map { band in
            let count = readings.filter { band.range.contains($0) }.count
            return StressBandShare(band: band,
                                   samples: count,
                                   minutes: count * max(1, series.intervalMinutes),
                                   percent: Double(count) / Double(readings.count) * 100)
        }
    }
}
