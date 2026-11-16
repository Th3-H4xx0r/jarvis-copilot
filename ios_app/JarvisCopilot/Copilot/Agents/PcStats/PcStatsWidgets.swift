import SwiftUI

// Look B ("Jarvis", his pick for PC Stats): near-black with a faint cool glow, the orb,
// soft glass panels, one big hero number over a glowing cool-blue area chart, compact
// meta rows, thin gradient bars. The panels are the app's own card (radius 20, glass
// fill, hairline) so the page still reads as part of the app; the cool blue is data
// colour, like `JcMetric` in Health, not the UI accent.

// MARK: - Look

enum PcLook {
    static let line = Color(jcHex: 0x8FDCFF)
    static let fill = Color(jcHex: 0x5CC8FF)
    static let barLo = Color(jcHex: 0x3FB6FF)
    static let barHi = Color(jcHex: 0x9FE7FF)
    static let track = Color.white.opacity(0.08)
    static let label = Color(jcHex: 0x8B929C)
    static let metaText = Color(jcHex: 0xA3A9B1)
    static let panel = Color.white.opacity(0.035)
    static let hairline = Color.white.opacity(0.07)
    static let radius: CGFloat = JcUnified.cardRadius

    /// Extra series in a multi-reading chart, after the widget's own colour.
    static let series: [Color] = [fill, Color(jcHex: 0xA78BFA), Color(jcHex: 0xFF9F6B),
                                  Color(jcHex: 0xC6E36B), Color(jcHex: 0xFF6FD8)]

    /// The colours the settings offer (`style.color`, #RRGGBB).
    static let palette: [String] = ["#5CC8FF", "#9FE7FF", "#7CB7FF", "#A78BFA", "#3EC7C7",
                                    "#C6E36B", "#FF9F6B", "#FF6FD8", "#FF5966", "#EDF0F8"]

    static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(jcHex: v)
    }

    static func seriesColor(_ i: Int, style: PcWidgetStyle) -> Color {
        if i == 0, let c = color(style.color) { return c }
        return series[i % series.count]
    }

    static func toneColor(_ tone: PcFormat.Tone) -> Color {
        switch tone {
        case .normal: return JcTheme.text
        case .warn: return JcTheme.amber
        case .crit: return JcTheme.danger
        }
    }

    /// The page's ground: black with the cool glow from the top right.
    static var backdrop: some View {
        ZStack {
            Color(jcHex: 0x050506)
            RadialGradient(colors: [Color(jcHex: 0x10202A), Color(jcHex: 0x050506).opacity(0)],
                           center: UnitPoint(x: 0.85, y: -0.05), startRadius: 0, endRadius: 520)
        }
    }
}

/// The Jarvis orb in the page header.
struct PcOrb: View {
    var size: CGFloat = 34
    var online = true

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(jcHex: 0x9FE7FF), Color(jcHex: 0x1B6C9E), Color(jcHex: 0x071A2A)],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.62))
            .frame(width: size, height: size)
            .shadow(color: Color(red: 80 / 255, green: 190 / 255, blue: 1).opacity(online ? 0.35 : 0.08), radius: 12)
            .saturation(online ? 1 : 0.15)
            .accessibilityHidden(true)
    }
}

/// A look-B panel: the app's card with look B's softer fill and hairline.
struct PcPanel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PcLook.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PcLook.panel, in: shape)
            .overlay(shape.strokeBorder(PcLook.hairline, lineWidth: 1))
            .clipShape(shape)
    }
}

/// The small "est." mark beside an estimated reading.
struct PcEstimatedBadge: View {
    var body: some View {
        Text("est.")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PcLook.label)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.white.opacity(0.07), in: Capsule())
            .accessibilityLabel("estimated")
    }
}

/// A widget's title line: its label, "est." when it's an estimate.
struct PcWidgetLabel: View {
    let text: String
    var estimated = false
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PcLook.label)
                .lineLimit(1)
            if estimated { PcEstimatedBadge() }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(PcLook.label).monospacedDigit()
            }
        }
    }
}

/// A big number with its unit in small grey after it, or "unavailable" with the reason.
struct PcBigValue: View {
    let value: PcValue
    var size: CGFloat = 56
    var tone: PcFormat.Tone = .normal
    var dimmed = false

    var body: some View {
        switch value {
        case .value(let n, let unit):
            HStack(alignment: .firstTextBaseline, spacing: unit.hasPrefix("°") || unit == "%" ? 1 : 4) {
                Text(n)
                    .font(.system(size: size, weight: .semibold))
                    .tracking(-size * 0.03)
                    .foregroundStyle(PcLook.toneColor(tone))
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(13, size * 0.36), weight: .medium))
                        .foregroundStyle(PcLook.label)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .opacity(dimmed ? 0.55 : 1)
        case .unavailable(let why):
            VStack(alignment: .leading, spacing: 2) {
                Text("Unavailable")
                    .font(.system(size: max(17, size * 0.38), weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(PcLook.label)
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
    /// The y range for a unit: 0–100 for percentages, a little headroom else; temperatures
    /// start a little under their lowest so the line has shape.
    static func range(_ values: [Double], unit: String, crit: Double? = nil) -> ClosedRange<Double> {
        if unit == "%" { return 0...100 }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let low = unit == "°C" ? max(0, (lo - 8).rounded(.down)) : 0
        var high = max(hi * 1.12, low + 1)
        if let crit, crit > high, crit < high * 1.4 { high = crit }
        return low...high
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

/// A smooth line (and optionally the glowing fill under it) through time-stamped points.
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
    var lineWidth: CGFloat = 2
    var band = false
    var markers: [Double] = []

    var body: some View {
        Canvas { ctx, size in
            for m in markers {
                let x = xPos(m, size)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(JcTheme.amber.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            for s in series.reversed() {
                for seg in PcChartScale.segments(s.points, span: span) {
                    let pts = seg.map { CGPoint(x: xPos($0.t, size), y: yPos($0.avg, size)) }
                    if band, seg.count > 1 {
                        var b = Path()
                        b.move(to: CGPoint(x: xPos(seg[0].t, size), y: yPos(seg[0].max, size)))
                        for p in seg.dropFirst() { b.addLine(to: CGPoint(x: xPos(p.t, size), y: yPos(p.max, size))) }
                        for p in seg.reversed() { b.addLine(to: CGPoint(x: xPos(p.t, size), y: yPos(p.min, size))) }
                        b.closeSubpath()
                        ctx.fill(b, with: .color(s.color.opacity(0.14)))
                    }
                    let line = Self.smooth(pts)
                    if area, let first = pts.first, let last = pts.last {
                        var fill = line
                        fill.addLine(to: CGPoint(x: last.x, y: size.height))
                        fill.addLine(to: CGPoint(x: first.x, y: size.height))
                        fill.closeSubpath()
                        ctx.fill(fill, with: .linearGradient(
                            Gradient(colors: [s.color.opacity(0.35), s.color.opacity(0)]),
                            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    if pts.count == 1, let p = pts.first {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(s.color))
                    } else {
                        let stroke = series.count == 1 && area ? PcLook.line : s.color
                        ctx.stroke(line, with: .color(stroke),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
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

    /// Catmull-Rom through the points, as cubic Béziers (the mockup's soft curve).
    static func smooth(_ pts: [CGPoint]) -> Path {
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

/// A thin horizontal bar with look B's gradient fill.
struct PcBar: View {
    let fraction: Double
    var color: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PcLook.track)
                Capsule()
                    .fill(color.map { AnyShapeStyle($0) } ??
                          AnyShapeStyle(LinearGradient(colors: [PcLook.barLo, PcLook.barHi], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A ring gauge.
struct PcRing: View {
    let fraction: Double
    var color: Color?
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(PcLook.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color.map { AnyShapeStyle($0) } ??
                        AnyShapeStyle(AngularGradient(colors: [PcLook.barLo, PcLook.barHi], center: .center,
                                                      startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, fraction)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
        .accessibilityHidden(true)
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

/// One widget in look B, at the height its kind needs on the phone.
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

/// "67° temp · 2715 MHz · 312 W" — the meta row's values, the reading's short name after.
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
        .font(.system(size: 12.5))
    }

    private func row(_ items: [(String, String)], gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.0).fontWeight(.semibold).foregroundStyle(JcTheme.text).monospacedDigit()
                    if !item.1.isEmpty { Text(item.1).foregroundStyle(PcLook.metaText) }
                }
                .fixedSize()
            }
        }
    }

    /// The muted word after a meta value (the unit already says the rest).
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
        let value = PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style)
        let chart = widget.style.chart ?? .area
        ZStack(alignment: .bottom) {
            if chart != .none, let key {
                let span = PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now)
                let pts = ctx.points(key, widget)
                PcLineChart(series: [.init(id: key, points: pts, color: PcLook.seriesColor(0, style: widget.style))],
                            span: span,
                            yRange: PcChartScale.range(pts.map(\.avg), unit: unit(key, ctx, widget.style), crit: widget.style.crit),
                            area: chart == .area)
                    .frame(height: 92)
                    .opacity(ctx.stale ? 0.5 : 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                PcWidgetLabel(text: widget.title(ctx.catalog),
                              estimated: PcFormat.isEstimated(key, live: ctx.live, catalog: ctx.catalog))
                if let temp = PcFormat.heroTemperature(widget) {
                    // Usage and temperature side by side at the hero size; the thresholds are the temperature's.
                    let tempStyle = PcFormat.heroTemperatureStyle(widget, key: temp)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        PcBigValue(value: value, size: 56, dimmed: ctx.stale)
                        Text("·")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(PcLook.label.opacity(0.6))
                        PcBigValue(value: PcFormat.heroTemperatureValue(temp, live: ctx.live, decimals: widget.style.decimals),
                                   size: 56, tone: PcFormat.tone(ctx.live.values[temp], style: tempStyle), dimmed: ctx.stale)
                    }
                    .lineLimit(1)
                    .padding(.top, 8)
                } else {
                    PcBigValue(value: value, size: 56, tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style),
                               dimmed: ctx.stale)
                        .padding(.top, 8)
                }
                let meta = PcFormat.heroMeta(widget)
                if !meta.isEmpty {
                    PcMetaRow(keys: meta, ctx: ctx).padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 216)
        .background(PcLook.panel, in: RoundedRectangle(cornerRadius: PcLook.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PcLook.radius, style: .continuous).strokeBorder(PcLook.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: PcLook.radius, style: .continuous))
    }
}

struct PcNumberWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        PcPanel(padding: 16) {
            PcWidgetLabel(text: widget.title(ctx.catalog),
                          estimated: PcFormat.isEstimated(key, live: ctx.live, catalog: ctx.catalog))
            Spacer(minLength: 6)
            PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 34,
                       tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style), dimmed: ctx.stale)
        }
        .frame(height: 112)
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
            PcWidgetLabel(text: widget.title(ctx.catalog),
                          estimated: PcFormat.isEstimated(key, live: ctx.live, catalog: ctx.catalog))
            Spacer(minLength: 6)
            HStack(spacing: 12) {
                ZStack {
                    PcRing(fraction: v == nil ? 0 : fraction,
                           color: tone == .normal ? PcLook.color(widget.style.color) : PcLook.toneColor(tone), lineWidth: 6)
                }
                .frame(width: 46, height: 46)
                .opacity(ctx.stale ? 0.55 : 1)
                PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 26,
                           tone: tone, dimmed: ctx.stale)
            }
        }
        .frame(height: 112)
    }
}

struct PcSparklineWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let key = widget.primary
        PcPanel(padding: 16) {
            PcWidgetLabel(text: widget.title(ctx.catalog),
                          estimated: PcFormat.isEstimated(key, live: ctx.live, catalog: ctx.catalog))
            PcBigValue(value: PcFormat.value(key, live: ctx.live, catalog: ctx.catalog, style: widget.style), size: 24,
                       tone: PcFormat.tone(key.flatMap { ctx.live.values[$0] }, style: widget.style), dimmed: ctx.stale)
                .padding(.top, 4)
            Spacer(minLength: 4)
            if let key {
                let pts = ctx.points(key, widget)
                PcLineChart(series: [.init(id: key, points: pts, color: PcLook.seriesColor(0, style: widget.style))],
                            span: PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now),
                            yRange: PcChartScale.range(pts.map(\.avg), unit: unit(key, ctx, widget.style)),
                            area: (widget.style.chart ?? .line) == .area, lineWidth: 1.5)
                    .frame(height: 26)
                    .opacity(ctx.stale ? 0.5 : 1)
            }
        }
        .frame(height: 112)
    }
}

struct PcChartWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let window = ctx.range.window(for: widget)
        let span = PcTimeSpan.last(window, now: ctx.now)
        let series = widget.readings.enumerated().map { i, key in
            PcLineChart.Series(id: key, points: ctx.points(key, widget), color: PcLook.seriesColor(i, style: widget.style))
        }
        let units = Set(widget.readings.map { unit($0, ctx, widget.style) })
        let all = series.flatMap { $0.points.map(\.avg) }
        let yRange = PcChartScale.range(all, unit: units.count == 1 ? units.first ?? "" : "", crit: widget.style.crit)
        PcPanel(padding: 18) {
            PcWidgetLabel(text: widget.title(ctx.catalog),
                          estimated: widget.readings.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) },
                          trailing: PcStatsCopy.window(window))
            legend(series)
                .padding(.top, 8)
            ZStack(alignment: .topTrailing) {
                if all.isEmpty {
                    Text(ctx.live.hasSample ? "No history in this window yet" : "No data yet")
                        .font(.footnote)
                        .foregroundStyle(PcLook.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PcLineChart(series: series, span: span, yRange: yRange,
                                area: (widget.style.chart ?? .line) == .area && series.count == 1)
                    Text(PcFormat.number(yRange.upperBound, unit: units.first ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(PcLook.label.opacity(0.8))
                        .monospacedDigit()
                }
            }
            .frame(height: 120)
            .padding(.top, 10)
            .opacity(ctx.stale ? 0.6 : 1)
        }
        .frame(height: 216)
    }

    private func legend(_ series: [PcLineChart.Series]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems(series) }
            VStack(alignment: .leading, spacing: 4) { legendItems(series) }
        }
    }

    @ViewBuilder
    private func legendItems(_ series: [PcLineChart.Series]) -> some View {
        ForEach(series) { s in
            HStack(spacing: 6) {
                Circle().fill(s.color).frame(width: 6, height: 6)
                Text(PcFormat.shortLabel(s.id, catalog: ctx.catalog)).foregroundStyle(PcLook.metaText)
                Text(ctx.live.values[s.id].map { PcFormat.compact($0, unit: ctx.catalog.info(s.id)?.unit ?? "") } ?? "—")
                    .fontWeight(.semibold)
                    .foregroundStyle(JcTheme.text)
                    .monospacedDigit()
            }
            .font(.system(size: 12.5))
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
            PcWidgetLabel(text: widget.title(ctx.catalog),
                          estimated: (headline.map { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) } ?? false)
                              || widget.readings.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) })
            if let headline {
                PcBigValue(value: PcFormat.value(headline, live: ctx.live, catalog: ctx.catalog,
                                                 style: PcWidgetStyle(decimals: widget.style.decimals)),
                           size: 34, dimmed: ctx.stale)
                    .padding(.top, 6)
            }
            VStack(spacing: 11) {
                ForEach(widget.readings, id: \.self) { key in
                    row(key, values: values)
                }
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
        return HStack(spacing: 10) {
            Text(PcFormat.shortLabel(key, catalog: ctx.catalog))
                .font(.system(size: 12.5))
                .foregroundStyle(PcLook.metaText)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            PcBar(fraction: PcFormat.barFraction(key, values: values, peers: widget.readings, catalog: ctx.catalog,
                                                 style: widget.style),
                  color: tone == .normal ? PcLook.color(widget.style.color) : PcLook.toneColor(tone))
            Text(available ? PcFormat.barValue(key, values: values, catalog: ctx.catalog, style: widget.style) : "n/a")
                .font(.system(size: 12.5, weight: available ? .semibold : .regular))
                .foregroundStyle(available ? JcTheme.text : PcLook.label)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PcFormat.shortLabel(key, catalog: ctx.catalog)) \(available ? PcFormat.barValue(key, values: values, catalog: ctx.catalog, style: widget.style) : "unavailable")")
    }
}

struct PcTextWidget: View {
    let widget: PcWidget

    var body: some View {
        Text(widget.style.label?.isEmpty == false ? widget.style.label! : "Text")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(JcTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

struct PcSessionWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        PcPanel(padding: 18) {
            if let game = ctx.live.game, ctx.live.online {
                PcWidgetLabel(text: widget.style.label ?? "Playing now")
                Text(game).font(.system(size: 22, weight: .semibold)).foregroundStyle(JcTheme.text).lineLimit(1).padding(.top, 6)
                HStack(spacing: 18) {
                    stat(ctx.live.values["fps"].map { PcFormat.number($0, unit: "fps") }, "fps")
                    stat(ctx.live.values["fps.low1"].map { PcFormat.number($0, unit: "fps") }, "1% low")
                    stat(ctx.live.values["power.total"].map { PcFormat.compact($0, unit: "W") }, "PC (est.)")
                }
                .padding(.top, 12)
            } else if let s = ctx.latestSession {
                PcWidgetLabel(text: widget.style.label ?? "Last session",
                              trailing: s.start.formatted(.relative(presentation: .named)))
                Text(s.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(JcTheme.text).lineLimit(1).padding(.top, 6)
                HStack(spacing: 18) {
                    stat(PcFormat.duration(s.duration(now: ctx.now)), "played")
                    stat(s.fpsAvg.map { PcFormat.number($0, unit: "fps") }, "avg fps")
                    stat(s.fpsLow1.map { PcFormat.number($0, unit: "fps") }, "1% low")
                    stat(s.energyWh.map { PcFormat.number($0, unit: "Wh") + " Wh" }, "energy")
                }
                .padding(.top, 12)
            } else {
                PcWidgetLabel(text: widget.style.label ?? "Game session")
                Text("No game sessions yet")
                    .font(.subheadline)
                    .foregroundStyle(PcLook.label)
                    .padding(.top, 10)
            }
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(.system(size: 15, weight: .semibold)).foregroundStyle(JcTheme.text).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(PcLook.label)
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
            PcWidgetLabel(text: widget.style.label ?? "Marked moments",
                          trailing: recent.isEmpty ? nil : "\(recent.count) today")
            // The day as a strip, each marked moment a tick.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PcLook.track).frame(height: 4)
                    ForEach(recent) { m in
                        let f = m.t.timeIntervalSince(dayAgo) / 86_400
                        Capsule()
                            .fill(PcMomentRow.color(m))
                            .frame(width: 3, height: 14)
                            .offset(x: max(0, min(geo.size.width - 3, geo.size.width * f)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            .padding(.top, 12)
            HStack {
                Text("24 h ago"); Spacer(); Text("now")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(PcLook.label)
            .padding(.top, 4)
            if recent.isEmpty {
                Text("Nothing marked in the last day")
                    .font(.footnote)
                    .foregroundStyle(PcLook.label)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recent.prefix(3)) { m in
                        Text("\(Text(m.t, format: .dateTime.hour().minute()).foregroundStyle(PcLook.label))  \(PcMomentRow.title(m, catalog: ctx.catalog))")
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.text)
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
        m.kind == "drop" || m.kind == "spike" ? JcTheme.amber : JcTheme.danger
    }
}
