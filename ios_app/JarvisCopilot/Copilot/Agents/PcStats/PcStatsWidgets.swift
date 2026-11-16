import SwiftUI

// The Apple look (docs/superpowers/specs/2026-11-15-pc-stats-apple-look.md; it replaced look B,
// which he found not professional enough): pure black, #1C1C1E borderless cards with a
// continuous 22 radius, a tinted SF Symbol + label per category (Apple system colours), large
// rounded tabular numerals with small secondary units, smoothed charts with three faint
// gridlines and a Min · Avg · Max row, Activity-style rings, 8 pt bars. Health / Fitness feel.

// MARK: - Look

enum PcLook {
    static let card = Color(jcHex: 0x1C1C1E)
    static let elevated = Color(jcHex: 0x2C2C2E)
    static let radius: CGFloat = 22
    static let primary = Color.white
    static let secondary = Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.6)
    static let tertiary = Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.3)
    static let separator = Color(.sRGB, red: 84 / 255, green: 84 / 255, blue: 88 / 255, opacity: 0.6)
    static let warn = Color(jcHex: 0xFF9F0A)
    static let crit = Color(jcHex: 0xFF453A)

    /// The colours the settings offer (`style.color`, #RRGGBB): the category tints and a few more.
    static let palette: [String] = ["#30D158", "#0A84FF", "#BF5AF2", "#FFD60A", "#64D2FF",
                                    "#5E5CE6", "#5AC8FA", "#FF9F0A", "#FF375F", "#FFFFFF"]

    static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(jcHex: v)
    }

    static func tint(_ category: PcCategory) -> Color { Color(jcHex: category.tintHex) }

    /// A reading's tint: its category's colour.
    static func tint(key: String?) -> Color { tint(PcCategory.of(key)) }

    /// A widget's tint: its own colour, else its first reading's category.
    static func tint(_ widget: PcWidget) -> Color {
        if let c = color(widget.style.color) { return c }
        switch widget.kind {
        case .session: return tint(.frames)
        case .moments: return tint(.temps)
        default: return tint(key: widget.primary)
        }
    }

    static func symbol(_ widget: PcWidget) -> String {
        switch widget.kind {
        case .session: return "gamecontroller.fill"
        case .moments: return "exclamationmark.triangle.fill"
        case .text: return "text.alignleft"
        default: return PcCategory.of(widget.primary).symbol
        }
    }

    /// The i-th series in a multi-reading chart: the widget's colour first, then distinct tints.
    static func seriesColor(_ i: Int, key: String, style: PcWidgetStyle, keys: [String]? = nil) -> Color {
        if i == 0, let c = color(style.color) { return c }
        let all = keys ?? [key]
        let hexes = PcCategory.seriesColors(all)
        return i < hexes.count && all.count > 1 ? Color(jcHex: hexes[i]) : tint(key: key)
    }

    /// Warn and crit colour the value text only.
    static func toneColor(_ tone: PcFormat.Tone) -> Color {
        switch tone {
        case .normal: return primary
        case .warn: return warn
        case .crit: return crit
        }
    }
}

/// A card: #1C1C1E, no border, continuous radius 22.
struct PcPanel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PcLook.card, in: RoundedRectangle(cornerRadius: PcLook.radius, style: .continuous))
    }
}

/// The small "est." mark beside an estimated reading.
struct PcEstimatedBadge: View {
    var body: some View {
        Text("est.")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PcLook.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(PcLook.elevated, in: Capsule())
            .accessibilityLabel("estimated")
    }
}

/// A card's header: the tinted symbol and label on the left, secondary context on the right.
struct PcCardHeader: View {
    let title: String
    var symbol: String?
    var tint: Color = PcLook.secondary
    var estimated = false
    var context: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            if estimated { PcEstimatedBadge() }
            Spacer(minLength: 6)
            if let context {
                Text(context)
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}

/// A header with no icon, for the history cards.
struct PcWidgetLabel: View {
    let text: String
    var estimated = false
    var trailing: String?

    var body: some View {
        PcCardHeader(title: text, tint: PcLook.secondary, estimated: estimated, context: trailing)
    }
}

/// A large rounded number with its unit small and secondary after it, or "Unavailable" with why.
struct PcBigValue: View {
    let value: PcValue
    var size: CGFloat = 52
    var tone: PcFormat.Tone = .normal
    var dimmed = false

    var body: some View {
        switch value {
        case .value(let n, let unit):
            HStack(alignment: .firstTextBaseline, spacing: unit.hasPrefix("°") || unit == "%" ? 1 : 3) {
                Text(n)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .tracking(-size * 0.02)
                    .foregroundStyle(PcLook.toneColor(tone))
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(12, size * 0.35), weight: .semibold, design: .rounded))
                        .foregroundStyle(PcLook.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .opacity(dimmed ? 0.55 : 1)
        case .unavailable(let why):
            VStack(alignment: .leading, spacing: 2) {
                Text("Unavailable")
                    .font(.system(size: max(17, size * 0.4), weight: .semibold, design: .rounded))
                    .foregroundStyle(PcLook.secondary)
                Text(why)
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Charts

/// The time span a chart draws.
struct PcTimeSpan: Equatable {
    let from: Double
    let to: Double

    static func last(_ seconds: Int, now: Date = Date()) -> PcTimeSpan {
        let t = now.timeIntervalSince1970
        return PcTimeSpan(from: t - Double(seconds), to: t)
    }
}

enum PcChartScale {
    static func range(_ values: [Double], unit: String) -> ClosedRange<Double> {
        PcChartMath.yRange(values, unit: unit)
    }

    /// Breaks a series where samples are missing for a while (the PC was off).
    static func segments(_ points: [PcPoint], span: PcTimeSpan) -> [[PcPoint]] {
        guard points.count > 1 else { return points.isEmpty ? [] : [points] }
        let steps = zip(points, points.dropFirst()).map { $1.t - $0.t }.sorted()
        let typical = steps[steps.count / 2]
        let gap = max(typical * 4, (span.to - span.from) / 60, 15)
        var out: [[PcPoint]] = [[points[0]]]
        for (a, b) in zip(points, points.dropFirst()) {
            if b.t - a.t > gap { out.append([b]) } else { out[out.count - 1].append(b) }
        }
        return out
    }
}

/// A smoothed line (and the tint fill under it) through time-stamped points, with optional
/// gridlines and their labels at the right edge.
struct PcLineChart: View {
    struct Series: Identifiable {
        let id: String
        let points: [PcPoint]
        let color: Color
    }

    let series: [Series]
    let span: PcTimeSpan
    let yRange: ClosedRange<Double>
    var area = true
    var lineWidth: CGFloat = 2.5
    var band = false
    var markers: [Double] = []
    var gridlines = false
    var unit = ""

    private let labelGutter: CGFloat = 34

    var body: some View {
        let plotInset = gridlines ? labelGutter : 0
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let plot = CGSize(width: max(1, size.width - plotInset), height: size.height)
                if gridlines {
                    for v in PcChartMath.gridlines(yRange) {
                        var p = Path()
                        let y = yPos(v, plot)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: plot.width, y: y))
                        ctx.stroke(p, with: .color(PcLook.separator), lineWidth: 1)
                    }
                }
                for m in markers {
                    let x = xPos(m, plot)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: plot.height))
                    ctx.stroke(p, with: .color(PcLook.warn.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for s in series.reversed() {
                    for seg in PcChartScale.segments(s.points, span: span) {
                        if band, seg.count > 1 {
                            var b = Path()
                            b.move(to: CGPoint(x: xPos(seg[0].t, plot), y: yPos(seg[0].max, plot)))
                            for p in seg.dropFirst() { b.addLine(to: CGPoint(x: xPos(p.t, plot), y: yPos(p.max, plot))) }
                            for p in seg.reversed() { b.addLine(to: CGPoint(x: xPos(p.t, plot), y: yPos(p.min, plot))) }
                            b.closeSubpath()
                            ctx.fill(b, with: .color(s.color.opacity(0.15)))
                        }
                        let smooth = PcChartMath.smooth(seg)
                        let pts = smooth.map { CGPoint(x: xPos($0.t, plot), y: yPos($0.avg, plot)) }
                        let line = Self.curve(pts)
                        if area, let first = pts.first, let last = pts.last, pts.count > 1 {
                            var fill = line
                            fill.addLine(to: CGPoint(x: last.x, y: plot.height))
                            fill.addLine(to: CGPoint(x: first.x, y: plot.height))
                            fill.closeSubpath()
                            ctx.fill(fill, with: .linearGradient(
                                Gradient(colors: [s.color.opacity(0.35), s.color.opacity(0)]),
                                startPoint: .zero, endPoint: CGPoint(x: 0, y: plot.height)))
                        }
                        if pts.count == 1, let p = pts.first {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(s.color))
                        } else {
                            ctx.stroke(line, with: .color(s.color),
                                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            if gridlines {
                GeometryReader { geo in
                    let plot = CGSize(width: geo.size.width - plotInset, height: geo.size.height)
                    ForEach(Array(PcChartMath.gridlines(yRange).enumerated()), id: \.offset) { _, v in
                        Text(PcFormat.number(v, unit: unit, decimals: yRange.upperBound < 10 ? 1 : 0))
                            .font(.system(size: 11))
                            .foregroundStyle(PcLook.tertiary)
                            .monospacedDigit()
                            .frame(width: labelGutter - 4, alignment: .trailing)
                            .position(x: geo.size.width - (labelGutter - 4) / 2, y: min(max(7, yPos(v, plot)), geo.size.height - 7))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func xPos(_ t: Double, _ size: CGSize) -> CGFloat {
        let w = max(1, span.to - span.from)
        return CGFloat((t - span.from) / w) * size.width
    }

    private func yPos(_ v: Double, _ size: CGSize) -> CGFloat {
        let h = max(0.0001, yRange.upperBound - yRange.lowerBound)
        let f = min(1, max(0, (v - yRange.lowerBound) / h))
        return size.height - CGFloat(f) * (size.height - 3) - 1.5
    }

    /// Catmull-Rom through the points, as cubic Béziers.
    static func curve(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            if pts.count == 2 { path.addLine(to: pts[1]) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// "Min 58 · Avg 66 · Max 72" under a chart.
struct PcStatRow: View {
    let points: [PcPoint]
    let unit: String

    var body: some View {
        if let line = PcChartMath.statLine(points, unit: unit) {
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(PcLook.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// An 8 pt bar on a #2C2C2E track.
struct PcBar: View {
    let fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PcLook.elevated)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint)
                    .frame(width: fraction > 0 ? max(8, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityHidden(true)
    }
}

/// An Activity-style ring: stroke 13% of the diameter, the tint's track at 20%.
struct PcRing: View {
    let fraction: Double
    var tint: Color
    var diameter: CGFloat = 92

    var body: some View {
        let stroke = diameter * 0.13
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(AngularGradient(colors: [tint, tint.mix(with: .white, by: 0.25)], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, min(1, fraction)))),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .padding(stroke / 2)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityHidden(true)
    }
}

private extension Color {
    /// `Color.mix` is iOS 18; this blends in sRGB on iOS 17 too.
    func mix(with other: Color, by amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return Color(.sRGB, red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t),
                     blue: Double(b1 + (b2 - b1) * t), opacity: Double(a1 + (a2 - a1) * t))
    }
}

// MARK: - Widgets

/// What every widget view reads.
struct PcWidgetContext {
    let live: PcLive
    let catalog: PcCatalog
    let range: PcRange
    let points: (String, PcWidget) -> [PcPoint]
    let latestSession: PcSession?
    let moments: [PcMoment]
    let now: Date

    /// Values are from an old sample (the PC is offline): drawn dimmed.
    var stale: Bool { !live.online }
}

/// One widget in the Apple look.
struct PcWidgetView: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        Group {
            switch widget.kind {
            case .hero: PcHeroWidget(widget: widget, ctx: ctx)
            case .number: PcNumberWidget(widget: widget, ctx: ctx)
            case .chart: PcChartWidget(widget: widget, ctx: ctx)
            case .bars: PcBarsWidget(widget: widget, ctx: ctx)
            case .ring: PcRingWidget(widget: widget, ctx: ctx)
            case .sparkline: PcSparklineWidget(widget: widget, ctx: ctx)
            case .text: PcTextWidget(widget: widget)
            case .session: PcSessionWidget(widget: widget, ctx: ctx)
            case .moments: PcMomentsWidget(widget: widget, ctx: ctx)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension PcWidget {
    /// The widget's title: its own label, else the reading's.
    func title(_ catalog: PcCatalog) -> String {
        if let l = style.label, !l.isEmpty { return l }
        if let k = primary, let r = catalog.info(k) { return r.label }
        return kind.title
    }
}

private func unit(_ key: String?, _ ctx: PcWidgetContext, _ style: PcWidgetStyle) -> String {
    style.unit ?? key.flatMap { ctx.catalog.info($0)?.unit } ?? ""
}

private func header(_ widget: PcWidget, _ ctx: PcWidgetContext, context: String? = nil,
                    estimated: Bool? = nil) -> PcCardHeader {
    PcCardHeader(title: widget.title(ctx.catalog), symbol: PcLook.symbol(widget), tint: PcLook.tint(widget),
                 estimated: estimated ?? PcFormat.isEstimated(widget.primary, live: ctx.live, catalog: ctx.catalog),
                 context: context)
}

/// "2715 MHz · 312 W · 9.8 GB VRAM": values primary, words secondary.
struct PcMetaRow: View {
    let keys: [String]
    let ctx: PcWidgetContext

    var body: some View {
        let items = keys.prefix(4).map { key -> (String, String) in
            let r = ctx.catalog.info(key)
            let v = ctx.live.values[key].map { PcFormat.compact($0, unit: r?.unit ?? "") } ?? "—"
            return (v, Self.word(key, ctx.catalog))
        }
        ViewThatFits(in: .horizontal) {
            row(items, gap: 16)
            row(Array(items.prefix(3)), gap: 12)
            row(Array(items.prefix(2)), gap: 12)
        }
        .font(.system(size: 13))
    }

    private func row(_ items: [(String, String)], gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.0).fontWeight(.semibold).foregroundStyle(PcLook.primary).monospacedDigit()
                    if !item.1.isEmpty { Text(item.1).foregroundStyle(PcLook.secondary) }
                }
                .fixedSize()
            }
        }
    }

    /// The secondary word after a meta value (the unit already says the rest).
    static func word(_ key: String, _ catalog: PcCatalog) -> String {
        switch key {
        case "gpu.temp", "cpu.temp": return "temp"
        case "gpu.hotspot": return "hotspot"
        case "gpu.vram_used": return "VRAM"
        case "fps.low1": return "1% low"
        case "frametime": return ""
        case "power.total": return "PC (est.)"
        case "ram.used": return "RAM"
        default:
            let unit = catalog.info(key)?.unit ?? ""
            return ["W", "MHz", "%", "°C", "ms", "fps"].contains(unit) ? "" : PcFormat.shortLabel(key, catalog: catalog)
        }
    }
}

struct PcHeroWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        let u = unit(key, ctx, widget.style)
        let value = PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style)
        let chart = widget.style.chart ?? .area
        let pts = key.map { ctx.points($0, widget) } ?? []
        let peak = pts.map(\.avg).max().map { "Peak \(PcFormat.compact($0, unit: u))" }
        PcPanel(padding: 18) {
            header(widget, ctx, context: ctx.stale ? "Last" : (peak ?? "Now"))
            valueRow(key: key, value: value)
                .padding(.top, 10)
            let meta = PcFormat.heroMeta(widget)
            if !meta.isEmpty {
                PcMetaRow(keys: meta, ctx: ctx).padding(.top, 6)
            }
            if chart != .none, let key {
                PcLineChart(series: [.init(id: key, points: pts, color: PcLook.tint(widget))],
                            span: PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now),
                            yRange: PcChartScale.range(pts.map(\.avg), unit: u),
                            area: chart == .area, gridlines: true, unit: u)
                    .frame(height: 132)
                    .padding(.top, 16)
                    .opacity(ctx.stale ? 0.5 : 1)
                PcStatRow(points: pts, unit: u).padding(.top, 10)
            }
        }
    }

    /// The usage, and for a load its temperature beside it at the same size ("96% · 67°C");
    /// warn/crit tint the temperature there, the value otherwise.
    @ViewBuilder
    private func valueRow(key: String?, value: PcValue) -> some View {
        if let temp = PcFormat.heroTemperature(widget) {
            let tempStyle = PcFormat.heroTemperatureStyle(widget, key: temp)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PcBigValue(value: value, size: 52, dimmed: ctx.stale)
                Text("·")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(PcLook.tertiary)
                PcBigValue(value: PcFormat.heroTemperatureValue(temp, live: ctx.live, decimals: widget.style.decimals),
                           size: 52, tone: PcFormat.tone(ctx.live.values[temp], style: tempStyle), dimmed: ctx.stale)
            }
            .lineLimit(1)
        } else {
            PcBigValue(value: value, size: 52, tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style),
                       dimmed: ctx.stale)
        }
    }
}

struct PcNumberWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        let u = unit(key, ctx, widget.style)
        let chart = widget.style.chart ?? .area
        let pts = key.map { ctx.points($0, widget) } ?? []
        PcPanel(padding: 16) {
            header(widget, ctx)
            PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 34,
                       tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style), dimmed: ctx.stale)
                .padding(.top, 8)
            Spacer(minLength: 8)
            if chart != .none, let key, !pts.isEmpty {
                PcLineChart(series: [.init(id: key, points: pts, color: PcLook.tint(widget))],
                            span: PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now),
                            yRange: PcChartScale.range(pts.map(\.avg), unit: u),
                            area: chart == .area, lineWidth: 2)
                    .frame(height: 44)
                    .opacity(ctx.stale ? 0.5 : 1)
            }
        }
        .frame(minHeight: 150)
    }
}

struct PcRingWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        let v = key.flatMap { ctx.live.values[$0] }
        let fraction = key.map { PcFormat.barFraction($0, values: ctx.live.values, peers: [$0], catalog: ctx.catalog,
                                                      style: widget.style) } ?? 0
        let tone = PcFormat.tone(v, style: widget.style)
        PcPanel(padding: 16) {
            header(widget, ctx)
            ZStack {
                PcRing(fraction: v == nil ? 0 : fraction, tint: PcLook.tint(widget), diameter: 88)
                    .opacity(ctx.stale ? 0.55 : 1)
                PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 24,
                           tone: tone, dimmed: ctx.stale)
                    .frame(maxWidth: 66)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            Text(key.map { PcFormat.shortLabel($0, catalog: ctx.catalog) } ?? "")
                .font(.system(size: 13))
                .foregroundStyle(PcLook.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }
}

struct PcSparklineWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        PcPanel(padding: 16) {
            header(widget, ctx)
            PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 28,
                       tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style), dimmed: ctx.stale)
                .padding(.top, 8)
            Spacer(minLength: 8)
            if let key {
                let pts = ctx.points(key, widget)
                PcLineChart(series: [.init(id: key, points: pts, color: PcLook.tint(widget))],
                            span: PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now),
                            yRange: PcChartScale.range(pts.map(\.avg), unit: unit(key, ctx, widget.style)),
                            area: (widget.style.chart ?? .line) == .area, lineWidth: 2)
                    .frame(height: 30)
                    .opacity(ctx.stale ? 0.5 : 1)
            }
        }
        .frame(minHeight: 150)
    }
}

struct PcChartWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let window = ctx.range.window(for: widget)
        let series = widget.readings.enumerated().map { i, key in
            PcLineChart.Series(id: key, points: ctx.points(key, widget), color: PcLook.seriesColor(i, key: key, style: widget.style, keys: widget.readings))
        }
        let units = Set(widget.readings.map { unit($0, ctx, widget.style) })
        let u = units.count == 1 ? units.first ?? "" : ""
        let all = series.flatMap { $0.points.map(\.avg) }
        PcPanel(padding: 18) {
            header(widget, ctx, context: PcStatsCopy.window(window),
                   estimated: widget.readings.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) })
            if series.count > 1 {
                legend(series).padding(.top, 10)
            } else if let key = widget.primary {
                PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 34,
                           tone: PcFormat.tone(ctx.live.values[key], style: widget.style), dimmed: ctx.stale)
                    .padding(.top, 8)
            }
            if all.isEmpty {
                Text(ctx.live.hasSample ? "No history in this window yet" : "No data yet")
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                PcLineChart(series: series, span: PcTimeSpan.last(window, now: ctx.now),
                            yRange: PcChartScale.range(all, unit: u),
                            area: (widget.style.chart ?? .line) == .area && series.count == 1,
                            gridlines: true, unit: u)
                    .frame(height: 132)
                    .padding(.top, 14)
                    .opacity(ctx.stale ? 0.6 : 1)
                if series.count == 1 { PcStatRow(points: series[0].points, unit: u).padding(.top, 10) }
            }
        }
    }

    private func legend(_ series: [PcLineChart.Series]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { legendItems(series) }
            VStack(alignment: .leading, spacing: 6) { legendItems(series) }
        }
    }

    @ViewBuilder
    private func legendItems(_ series: [PcLineChart.Series]) -> some View {
        ForEach(series) { s in
            HStack(spacing: 6) {
                Circle().fill(s.color).frame(width: 8, height: 8)
                Text(PcFormat.shortLabel(s.id, catalog: ctx.catalog)).foregroundStyle(PcLook.secondary)
                Text(ctx.live.values[s.id].map { PcFormat.compact($0, unit: ctx.catalog.info(s.id)?.unit ?? "") } ?? "—")
                    .fontWeight(.semibold)
                    .foregroundStyle(PcLook.primary)
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .fixedSize()
        }
    }
}

struct PcBarsWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let values = ctx.live.values
        let headline = widget.style.meta.first
        PcPanel(padding: 18) {
            header(widget, ctx,
                   estimated: (headline.map { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) } ?? false)
                       || widget.readings.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) })
            if let headline {
                PcBigValue(value: PcFormat.value(headline, live: ctx.live, catalog: ctx.catalog,
                                                 style: PcWidgetStyle(decimals: widget.style.decimals)),
                           size: 34, dimmed: ctx.stale)
                    .padding(.top, 8)
            }
            VStack(spacing: 14) {
                ForEach(widget.readings, id: \.self) { key in row(key, values: values) }
            }
            .padding(.top, 14)
            .opacity(ctx.stale ? 0.6 : 1)
            if widget.style.meta.count > 1 {
                PcMetaRow(keys: Array(widget.style.meta.dropFirst()), ctx: ctx).padding(.top, 14)
            }
        }
    }

    private func row(_ key: String, values: [String: Double]) -> some View {
        let available = values[key] != nil
        let tone = PcFormat.tone(values[key], style: widget.style)
        let label = PcFormat.shortLabel(key, catalog: ctx.catalog)
        let text = available ? PcFormat.barValue(key, values: values, catalog: ctx.catalog, style: widget.style) : "Unavailable"
        let tint = widget.readings.count > 1 && widget.style.color == nil ? PcLook.tint(key: key) : PcLook.tint(widget)
        return VStack(spacing: 6) {
            HStack {
                Text(label).font(.system(size: 14)).foregroundStyle(PcLook.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(text)
                    .font(.system(size: 14, weight: available ? .semibold : .regular))
                    .foregroundStyle(available ? PcLook.toneColor(tone) : PcLook.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            PcBar(fraction: PcFormat.barFraction(key, values: values, peers: widget.readings, catalog: ctx.catalog,
                                                 style: widget.style),
                  tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(text)")
    }
}

struct PcTextWidget: View {
    let widget: PcWidget

    var body: some View {
        Text(widget.style.label?.isEmpty == false ? widget.style.label! : "Text")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(PcLook.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }
}

struct PcSessionWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        PcPanel(padding: 18) {
            if let game = ctx.live.game, ctx.live.online {
                PcCardHeader(title: widget.style.label ?? "Playing now", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget))
                Text(game).font(.system(size: 22, weight: .semibold)).foregroundStyle(PcLook.primary).lineLimit(1).padding(.top, 8)
                HStack(spacing: 22) {
                    stat(ctx.live.values["fps"].map { PcFormat.number($0, unit: "fps") }, "fps")
                    stat(ctx.live.values["fps.low1"].map { PcFormat.number($0, unit: "fps") }, "1% low")
                    stat(ctx.live.values["power.total"].map { PcFormat.compact($0, unit: "W") }, "PC (est.)")
                }
                .padding(.top, 14)
            } else if let s = ctx.latestSession {
                PcCardHeader(title: widget.style.label ?? "Last session", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget),
                             context: s.start.formatted(.relative(presentation: .named)))
                Text(s.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(PcLook.primary).lineLimit(1).padding(.top, 8)
                HStack(spacing: 22) {
                    stat(PcFormat.duration(s.duration(now: ctx.now)), "played")
                    stat(s.fpsAvg.map { PcFormat.number($0, unit: "fps") }, "avg fps")
                    stat(s.fpsLow1.map { PcFormat.number($0, unit: "fps") }, "1% low")
                    stat(s.energyWh.map { PcFormat.number($0, unit: "Wh") + " Wh" }, "energy")
                }
                .padding(.top, 14)
            } else {
                PcCardHeader(title: widget.style.label ?? "Game session", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget))
                Text("No game sessions yet")
                    .font(.system(size: 15))
                    .foregroundStyle(PcLook.secondary)
                    .padding(.top, 10)
            }
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(PcLook.primary)
                .monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(PcLook.secondary)
        }
        .fixedSize()
    }
}

struct PcMomentsWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let dayAgo = ctx.now.addingTimeInterval(-86_400)
        let recent = ctx.moments.filter { $0.t >= dayAgo }
        PcPanel(padding: 18) {
            PcCardHeader(title: widget.style.label ?? "Marked moments", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget),
                         context: recent.isEmpty ? "Last 24 h" : "\(recent.count) in 24 h")
            // The day as a strip, each marked moment a tick.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PcLook.elevated).frame(height: 8)
                    ForEach(recent) { m in
                        let f = m.t.timeIntervalSince(dayAgo) / 86_400
                        Capsule()
                            .fill(PcMomentRow.color(m))
                            .frame(width: 4, height: 16)
                            .offset(x: max(0, min(geo.size.width - 4, geo.size.width * f)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            .padding(.top, 14)
            HStack { Text("24 h ago"); Spacer(); Text("Now") }
                .font(.system(size: 11))
                .foregroundStyle(PcLook.tertiary)
                .padding(.top, 4)
            if recent.isEmpty {
                Text("Nothing marked in the last day")
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recent.prefix(3)) { m in
                        Text("\(Text(m.t, format: .dateTime.hour().minute()).foregroundStyle(PcLook.secondary))  \(PcMomentRow.title(m, catalog: ctx.catalog))")
                            .font(.system(size: 14))
                            .foregroundStyle(PcLook.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

/// A marked moment's words and colour, shared by the widget and the history list.
enum PcMomentRow {
    static func title(_ m: PcMoment, catalog: PcCatalog) -> String {
        if !m.label.isEmpty { return m.label }
        let name = catalog.info(m.key)?.label ?? m.key
        switch m.kind {
        case "hot", "over": return "\(name) high"
        case "spike": return "Power spike"
        case "drop": return "Frame drop"
        case "throttle": return "Throttling"
        default: return name.isEmpty ? "Marked moment" : name
        }
    }

    static func detail(_ m: PcMoment, catalog: PcCatalog) -> String {
        let unit = catalog.info(m.key)?.unit ?? ""
        var parts: [String] = []
        if let v = m.value { parts.append(PcFormat.compact(v, unit: unit)) }
        if let t = m.threshold { parts.append("limit \(PcFormat.compact(t, unit: unit))") }
        if let d = m.durationS, d > 0 { parts.append("for \(PcFormat.duration(d))") }
        return parts.joined(separator: " · ")
    }

    static func color(_ m: PcMoment) -> Color {
        m.kind == "drop" || m.kind == "spike" ? PcLook.warn : PcLook.crit
    }
}
