import Charts
import SwiftUI

/// A route's profile against distance.
enum RouteChartKind: String, CaseIterable, Identifiable {
    case elevation, pace, heartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevation: return "Elevation"
        case .pace: return "Pace"
        case .heartRate: return "Heart rate"
        }
    }

    var tint: Color {
        switch self {
        case .elevation: return JcTheme.accent
        case .pace: return JcTheme.amber
        case .heartRate: return RingMeasurementType.heartRate.tint
        }
    }
}

/// One point of a profile: how far along (in the unit), and the value
/// (elevation in m or ft, pace in seconds per unit, bpm).
struct RouteChartPoint: Identifiable, Equatable {
    var id: Int
    var x: Double
    var y: Double
}

enum RouteChartSeries {
    /// At most `limit` points, averaged by distance: a long route charts as smoothly as a short one.
    static func points(_ kind: RouteChartKind, stats: RouteStats, unit: DistanceUnit, limit: Int = 300) -> [RouteChartPoint] {
        let raw: [(Double, Double)] = stats.samples.compactMap { sample in
            let x = sample.distance / unit.meters
            switch kind {
            case .elevation:
                return sample.ele.map { (x, unit == .km ? $0 : $0 * DistanceUnit.feetPerMeter) }
            case .pace:
                guard let speed = sample.speed, speed >= RouteMath.movingSpeed else { return nil }
                return (x, unit.meters / speed)
            case .heartRate:
                return sample.hr.map { (x, Double($0)) }
            }
        }
        guard raw.count >= 2, let total = raw.last?.0, total > 0 else { return [] }
        var buckets = [[Double]](repeating: [], count: limit)
        var xs = [Double](repeating: 0, count: limit)
        for (x, y) in raw {
            let i = min(limit - 1, Int(x / total * Double(limit)))
            buckets[i].append(y)
            xs[i] = x
        }
        var out: [RouteChartPoint] = []
        for i in 0..<limit where !buckets[i].isEmpty {
            out.append(RouteChartPoint(id: i, x: xs[i], y: buckets[i].reduce(0, +) / Double(buckets[i].count)))
        }
        if kind == .pace, out.count > 4 {
            // A stop or a GPS stumble makes a pace the chart would be all about: cap it.
            let sorted = out.map(\.y).sorted()
            let cap = sorted[Int(Double(sorted.count - 1) * 0.95)] * 1.15
            out = out.map { RouteChartPoint(id: $0.id, x: $0.x, y: min($0.y, cap)) }
        }
        return out
    }

    /// The point nearest a distance along the route.
    static func nearest(_ points: [RouteChartPoint], to x: Double) -> RouteChartPoint? {
        points.min { abs($0.x - x) < abs($1.x - x) }
    }
}

/// A profile chart, scrubbed with a finger: the scrub is shared by every
/// chart on the screen and the map's dot.
struct RouteProfileChart: View {
    let kind: RouteChartKind
    let points: [RouteChartPoint]
    let unit: DistanceUnit
    @Binding var scrub: Double?

    var body: some View {
        let ys = points.map(\.y)
        let lo = ys.min() ?? 0, hi = ys.max() ?? 1
        let span = max(hi - lo, kind == .elevation ? (unit == .km ? 20 : 60) : kind == .pace ? 60 : 10)
        let floor = lo - span * 0.15, ceiling = lo + span * 1.1
        let marked = scrub.flatMap { RouteChartSeries.nearest(points, to: $0) }
        Chart {
            ForEach(points) { point in
                if kind == .elevation {
                    AreaMark(x: .value("Distance", point.x), yStart: .value("Floor", floor), yEnd: .value(kind.title, point.y))
                        .foregroundStyle(LinearGradient(colors: [kind.tint.opacity(0.35), kind.tint.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Distance", point.x), y: .value(kind.title, point.y))
                    .foregroundStyle(kind.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            if let marked {
                RuleMark(x: .value("Distance", marked.x))
                    .foregroundStyle(Color.white.opacity(0.35))
                PointMark(x: .value("Distance", marked.x), y: .value(kind.title, marked.y))
                    .foregroundStyle(kind.tint)
                    .symbolSize(70)
            }
        }
        .chartXSelection(value: $scrub)
        .chartXScale(domain: 0...max(0.01, points.last?.x ?? 1))
        .modifier(RouteYScale(pace: kind == .pace, floor: floor, ceiling: ceiling))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let x = value.as(Double.self) { Text(String(format: x < 10 ? "%.1f" : "%.0f", x) + " \(unit.symbol)") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let y = value.as(Double.self) { Text(label(y)) }
                }
            }
        }
    }

    private func label(_ y: Double) -> String {
        switch kind {
        case .elevation: return Int(y.rounded()).formatted()
        case .pace: return unit.pace(secondsPerMeter: y / unit.meters)
        case .heartRate: return "\(Int(y.rounded()))"
        }
    }
}

/// The value axis: fitted to the route; pace upside down, so faster is higher.
private struct RouteYScale: ViewModifier {
    let pace: Bool
    let floor: Double
    let ceiling: Double

    func body(content: Content) -> some View {
        if pace {
            content.chartYScale(domain: .automatic(includesZero: false, reversed: true))
        } else {
            content.chartYScale(domain: floor...ceiling)
        }
    }
}
