import SwiftUI

// The Jarvis look (docs/superpowers/specs/2026-11-15-pc-stats-jarvis-look.md; his ask: "more
// jarvis themed and match it with the app UI we have right now"). Every colour is an app token:
// the accent (`JcAccent.color`, the one variable) in shades for data, `JcTheme` text / muted,
// `JcButton` greys for controls, the app's amber / red only past warn / crit. Cards are the
// app's `JcCard`; card headers are the small muted uppercase section-label style.

// MARK: - Look

enum PcLook {
    static let accent = JcAccent.color
    static let radius: CGFloat = JcUnified.cardRadius
    /// Between cards.
    static let gap: CGFloat = 12
    static let primary = JcTheme.text
    static let secondary = JcTheme.muted
    static let tertiary = JcTheme.muted.opacity(0.6)
    /// Gridlines and hairlines.
    static let separator = JcAccent.color.opacity(0.07)
    /// A bar's empty track.
    static let track = JcAccent.color.opacity(0.08)
    /// Grey control surface (switcher pill).
    static let control = JcButton.fill
    static let warn = JcTheme.amber
    static let crit = JcTheme.danger

    /// The accent at a strength (0…1).
    static func accent(_ opacity: Double) -> Color { JcAccent.color.opacity(opacity) }

    /// A metric group's data colour (`JcMetric.pc*`, defined once in Shared/JcAccent.swift).
    static func metric(_ category: PcCategory) -> Color {
        switch category {
        case .gpu: return JcMetric.pcGpu
        case .cpu: return JcMetric.pcCpu
        case .frames: return JcMetric.pcFrames
        case .power: return JcMetric.pcPower
        case .temps: return JcMetric.pcTemps
        case .memory: return JcMetric.pcMemory
        case .network: return JcMetric.pcNetwork
        case .cooling: return JcMetric.pcCooling
        case .other: return JcTheme.muted
        }
    }

    /// Data colour (lines, fills, rings, bars, sparklines, legend dots, header icon). Chrome
    /// (cards, labels, values, controls) never uses it.
    static func tint(_ category: PcCategory) -> Color { metric(category) }
    static func tint(key: String?) -> Color { metric(PcCategory.of(key)) }
    static func tint(_ widget: PcWidget) -> Color {
        switch widget.kind {
        case .session: return metric(.frames)
        case .moments: return metric(.temps)
        case .hero: return metric(widget.primary.map(PcCategory.part) ?? .other)
        default: return metric(PcCategory.of(widget.primary))
        }
    }

    static func symbol(_ widget: PcWidget) -> String {
        switch widget.kind {
        case .session: return "gamecontroller"
        case .moments: return "exclamationmark.triangle"
        case .text: return "text.alignleft"
        default: return PcCategory.of(widget.primary).symbol
        }
    }

    /// The i-th line of a chart: its own group's colour (a repeat from the same group at 55 % / 30 %).
    static func seriesColor(_ i: Int, key: String = "", style: PcWidgetStyle = PcWidgetStyle(), keys: [String]? = nil) -> Color {
        let shades = PcCategory.seriesShades(keys ?? [key])
        guard i < shades.count else { return tint(key: key) }
        return metric(shades[i].category).opacity(shades[i].opacity)
    }

    /// Warn and crit colour the value text (and that bar or ring) only.
    static func toneColor(_ tone: PcFormat.Tone) -> Color {
        switch tone {
        case .normal: return primary
        case .warn: return warn
        case .crit: return crit
        }
    }

    /// A bar or ring's fill: the accent, or amber / red past the widget's thresholds.
    static func fill(_ tone: PcFormat.Tone, normal: Color = JcAccent.color) -> Color {
        tone == .normal ? normal : toneColor(tone)
    }
}

/// A game's Windows icon with 6 pt rounded corners; a muted controller in a grey square when the
/// PC hasn't sent one (or it doesn't decode).
struct PcGameIcon: View {
    let game: PcGame?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let data = game?.icon, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: size, height: size)
                    .background(JcButton.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 6 / 22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A card: the app's `JcCard` (surface, hairline, radius 20), filling the height it's given so
/// two tiles side by side match.
struct PcPanel<Content: View>: View {
    var padding: CGFloat = JcUnified.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        JcCard(padding: padding) {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }
}

/// "EST." beside an estimated reading, in the header's small muted caps.
struct PcEstimatedBadge: View {
    var body: some View {
        Text("EST.")
            .font(.system(size: 11, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(PcLook.tertiary)
            .accessibilityLabel("estimated")
    }
}

/// A card's header in the app's section-label style: a small muted icon, the label in small
/// muted UPPERCASE with letter-spacing, and the context ("NOW", "10 MIN") on the right.
struct PcCardHeader: View {
    let title: String
    var symbol: String?
    /// The icon's data colour; the label and context stay muted.
    var tint: Color = JcTheme.muted
    var estimated = false
    var context: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(title.uppercased())
                .font(.system(size: 12, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(PcLook.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if estimated { PcEstimatedBadge() }
            Spacer(minLength: 6)
            if let context {
                Text(context.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .tracking(0.8)
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
        PcCardHeader(title: text, estimated: estimated, context: trailing)
    }
}

/// A big bold white number with its unit small and muted after it ("65°" inline), or
/// "Unavailable" with why.
struct PcBigValue: View {
    let value: PcValue
    var size: CGFloat = 52
    var tone: PcFormat.Tone = .normal
    var dimmed = false

    var body: some View {
        switch value {
        case .value(let raw, let rawUnit):
            let n = rawUnit == "°" ? raw + "°" : raw
            let unit = rawUnit == "°" ? "" : rawUnit
            HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 3) {
                Text(n)
                    .font(.system(size: size, weight: .bold))
                    .tracking(-size * 0.02)
                    .foregroundStyle(PcLook.toneColor(tone))
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(12, size * 0.35), weight: .semibold))
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
                    .font(.system(size: max(17, size * 0.4), weight: .semibold))
                    .foregroundStyle(PcLook.secondary)
                Text(why)
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Wrapping row

/// Items left to right, wrapping onto the next line instead of ever running past the width it's
/// given; an item wider than a whole line is proposed the line's width (its text truncates).
struct PcFlow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    private func sizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { v in
            let ideal = v.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            let fitted = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            return CGSize(width: min(maxWidth, fitted.width), height: fitted.height)
        }
    }

    private func lines(_ sizes: [CGSize], maxWidth: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if !out[out.count - 1].isEmpty, x + spacing + s.width > maxWidth {
                out.append([])
                x = 0
            }
            x += (out[out.count - 1].isEmpty ? 0 : spacing) + s.width
            out[out.count - 1].append(i)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let s = sizes(subviews, maxWidth: maxWidth)
        let ls = lines(s, maxWidth: maxWidth)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (n, line) in ls.enumerated() {
            var w: CGFloat = 0
            var h: CGFloat = 0
            for (k, i) in line.enumerated() {
                w += s[i].width + (k == 0 ? 0 : spacing)
                h = max(h, s[i].height)
            }
            width = max(width, w)
            height += h + (n == 0 ? 0 : lineSpacing)
        }
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = sizes(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for l in lines(s, maxWidth: bounds.width) {
            var x = bounds.minX
            let h = l.map { s[$0].height }.max() ?? 0
            for i in l {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s[i]))
                x += s[i].width + spacing
            }
            y += h + lineSpacing
        }
    }
}

/// Two tiles side by side at equal width and height only when EACH fits whole in half the
/// width; otherwise one above the other at full width.
struct PcPairLayout: Layout {
    var spacing: CGFloat = 12

    static func sideBySide(idealWidths: [CGFloat], width: CGFloat, spacing: CGFloat) -> Bool {
        guard idealWidths.count == 2, width.isFinite else { return false }
        let half = (width - spacing) / 2
        return idealWidths.allSatisfy { $0 <= half }
    }

    private func split(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        Self.sideBySide(idealWidths: subviews.map { $0.sizeThatFits(.unspecified).width }, width: width, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, ideal.count - 1)),
                          height: ideal.map(\.height).max() ?? 0)
        }
        if split(width, subviews) {
            let half = (width - spacing) / 2
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: half, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: h)
        }
        let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: hs.reduce(0, +) + spacing * CGFloat(max(0, hs.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if split(bounds.width, subviews) {
            let half = (bounds.width - spacing) / 2
            for (i, v) in subviews.enumerated() {
                v.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (half + spacing), y: bounds.minY),
                        proposal: ProposedViewSize(width: half, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for v in subviews {
                let h = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                v.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
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
    var lineWidth: CGFloat = 2
    var band = false
    var markers: [Double] = []
    var gridlines = false
    var unit = ""
    /// The area fill's top opacity (of the series colour), fading to 0.
    var areaOpacity: Double = 0.22
    /// Faint dashed lines at the widget's warn / crit.
    var thresholds: [(value: Double, color: Color)] = []

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
                for th in thresholds where yRange.contains(th.value) {
                    var p = Path()
                    let y = yPos(th.value, plot)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: plot.width, y: y))
                    ctx.stroke(p, with: .color(th.color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
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
                            ctx.fill(b, with: .color(s.color.opacity(0.12)))
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
                                Gradient(colors: [s.color.opacity(areaOpacity), s.color.opacity(0)]),
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

/// An 8 pt bar: the fill (the reading's colour, or amber / red past a threshold) on a white track at 8 %.
struct PcBar: View {
    let fraction: Double
    var tint: Color = JcAccent.color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PcLook.track)
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

/// A ring: the arc (the reading's colour, or amber / red past a threshold) with round caps on a
/// track of the reading's colour at 18 %; stroke 13 % of the diameter.
struct PcRing: View {
    let fraction: Double
    var tint: Color = JcAccent.color
    var track: Color?
    var diameter: CGFloat = 92

    var body: some View {
        let stroke = diameter * 0.13
        ZStack {
            Circle().stroke((track ?? tint).opacity(0.18), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .padding(stroke / 2)
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
            case .stats: PcStatsTileWidget(widget: widget, ctx: ctx)
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

/// The widget's warn / crit as faint dashed chart lines.
private func thresholdLines(_ style: PcWidgetStyle) -> [(value: Double, color: Color)] {
    var out: [(value: Double, color: Color)] = []
    if let w = style.warn { out.append((w, PcLook.warn)) }
    if let c = style.crit { out.append((c, PcLook.crit)) }
    return out
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
        // One tidy line with as many as fit; the last option wraps, so it always fits.
        ViewThatFits(in: .horizontal) {
            row(items, gap: 16)
            row(Array(items.prefix(3)), gap: 14)
            PcFlow(spacing: 14) { cells(items) }
        }
        .font(.system(size: 13))
    }

    private func row(_ items: [(String, String)], gap: CGFloat) -> some View {
        HStack(spacing: gap) { cells(items) }
    }

    @ViewBuilder
    private func cells(_ items: [(String, String)]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            HStack(spacing: 4) {
                Text(item.0).fontWeight(.semibold).foregroundStyle(PcLook.primary).monospacedDigit()
                if !item.1.isEmpty { Text(item.1).foregroundStyle(PcLook.secondary) }
            }
            .lineLimit(1)
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
        case "power.gpu", "power.cpu", "power.ram", "power.disk", "power.net": return PcFormat.shortLabel(key, catalog: catalog)
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
                            area: chart == .area, gridlines: true, unit: u,
                            thresholds: PcFormat.heroTemperature(widget) == nil ? thresholdLines(widget.style) : [])
                    .frame(height: 132)
                    .padding(.top, 16)
                    .opacity(ctx.stale ? 0.5 : 1)
                PcStatRow(points: pts, unit: u).padding(.top, 10)
            }
        }
    }

    private func loadAndTemp(_ value: PcValue, _ temp: PcValue, tone: PcFormat.Tone, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.18) {
            PcBigValue(value: value, size: size, dimmed: ctx.stale).layoutPriority(1)
            Text("·")
                .font(.system(size: size * 0.7, weight: .semibold, design: .rounded))
                .foregroundStyle(PcLook.tertiary)
            PcBigValue(value: temp, size: size, tone: tone, dimmed: ctx.stale).layoutPriority(1)
        }
        .lineLimit(1)
    }

    /// The usage, and for a load its temperature beside it at the same size ("96% · 67°");
    /// warn/crit tint the temperature there, the value otherwise.
    @ViewBuilder
    private func valueRow(key: String?, value: PcValue) -> some View {
        if let temp = PcFormat.heroTemperature(widget) {
            let tempStyle = PcFormat.heroTemperatureStyle(widget, key: temp)
            let tempValue = PcFormat.heroTemperatureValue(temp, live: ctx.live, decimals: widget.style.decimals)
            let tone = PcFormat.tone(ctx.live.values[temp], style: tempStyle)
            // The biggest size at which "98% · 65°" fits on one line; the last one shrinks to fit.
            ViewThatFits(in: .horizontal) {
                ForEach([52, 44, 36] as [CGFloat], id: \.self) { size in
                    loadAndTemp(value, tempValue, tone: tone, size: size)
                }
            }
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
                            area: chart == .area, lineWidth: 2, thresholds: thresholdLines(widget.style))
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
                PcRing(fraction: v == nil ? 0 : fraction, tint: PcLook.fill(tone, normal: PcLook.tint(widget)),
                       track: PcLook.tint(widget), diameter: 88)
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
                            area: (widget.style.chart ?? .line) == .area, lineWidth: 2, areaOpacity: 0.14)
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
        let keys = PcFormat.expand(widget.readings, live: ctx.live)
        let series = keys.enumerated().map { i, key in
            PcLineChart.Series(id: key, points: ctx.points(key, widget), color: PcLook.seriesColor(i, key: key, style: widget.style, keys: keys))
        }
        let units = Set(keys.map { unit($0, ctx, widget.style) })
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
                            gridlines: true, unit: u,
                            thresholds: series.count == 1 ? thresholdLines(widget.style) : [])
                    .frame(height: 132)
                    .padding(.top, 14)
                    .opacity(ctx.stale ? 0.6 : 1)
                if series.count == 1 { PcStatRow(points: series[0].points, unit: u).padding(.top, 10) }
            }
        }
    }

    private func legend(_ series: [PcLineChart.Series]) -> some View {
        PcFlow(spacing: 16) { legendItems(series) }
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
            .lineLimit(1)
        }
    }
}

struct PcBarsWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let values = ctx.live.values
        let headline = widget.style.meta.first
        let keys = PcFormat.expand(widget.readings, live: ctx.live)
        PcPanel(padding: 18) {
            header(widget, ctx,
                   estimated: (headline.map { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) } ?? false)
                       || keys.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) })
            if let headline {
                PcBigValue(value: PcFormat.value(headline, live: ctx.live, catalog: ctx.catalog,
                                                 style: PcWidgetStyle(decimals: widget.style.decimals)),
                           size: 34, dimmed: ctx.stale)
                    .padding(.top, 8)
            }
            VStack(spacing: 14) {
                ForEach(keys, id: \.self) { key in row(key, values: values, peers: keys) }
            }
            .padding(.top, 14)
            .opacity(ctx.stale ? 0.6 : 1)
            if widget.style.meta.count > 1 {
                PcMetaRow(keys: Array(widget.style.meta.dropFirst()), ctx: ctx).padding(.top, 14)
            }
        }
    }

    private func row(_ key: String, values: [String: Double], peers: [String]) -> some View {
        let available = values[key] != nil
        let tone = PcFormat.tone(values[key], style: widget.style)
        let label = PcFormat.shortLabel(key, catalog: ctx.catalog)
        let text = available ? PcFormat.barValue(key, values: values, catalog: ctx.catalog, style: widget.style) : "Unavailable"
        let tint = PcLook.fill(tone, normal: PcLook.tint(key: key))
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
            PcBar(fraction: PcFormat.barFraction(key, values: values, peers: peers, catalog: ctx.catalog,
                                                 style: widget.style),
                  tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(text)")
    }
}

/// A detail tile: labelled numbers two to a row, each with a tiny sparkline under it.
struct PcStatsTileWidget: View {
    let widget: PcWidget
    let ctx: PcWidgetContext

    var body: some View {
        let keys = PcFormat.expand(widget.readings, live: ctx.live)
        PcPanel(padding: 18) {
            header(widget, ctx, estimated: keys.contains { PcFormat.isEstimated($0, live: ctx.live, catalog: ctx.catalog) })
            if keys.isEmpty {
                Text(ctx.live.hasSample ? "None reported by this PC" : "No data yet")
                    .font(.system(size: 13))
                    .foregroundStyle(PcLook.secondary)
                    .padding(.top, 10)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                                    GridItem(.flexible(), spacing: 16, alignment: .topLeading)],
                          alignment: .leading, spacing: 16) {
                    ForEach(keys, id: \.self) { key in cell(key) }
                }
                .padding(.top, 14)
            }
        }
    }

    private func cell(_ key: String) -> some View {
        let c = PcFormat.statsCell(key, live: ctx.live, catalog: ctx.catalog, style: widget.style)
        let pts = ctx.points(key, widget)
        let tone = PcFormat.tone(ctx.live.values[key], style: widget.style)
        let tint = PcLook.tint(key: key)
        return VStack(alignment: .leading, spacing: 3) {
            Text(c.label)
                .font(.system(size: 13))
                .foregroundStyle(PcLook.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(c.value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(c.value == "—" ? PcLook.tertiary : PcLook.toneColor(tone))
                    .contentTransition(.numericText())
                if !c.unit.isEmpty {
                    Text(c.unit)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(PcLook.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .opacity(ctx.stale ? 0.55 : 1)
            PcLineChart(series: [.init(id: key, points: pts, color: tint)],
                        span: PcTimeSpan.last(ctx.range.window(for: widget), now: ctx.now),
                        yRange: PcChartScale.range(pts.map(\.avg), unit: unit(key, ctx, widget.style)),
                        area: true, lineWidth: 1.5, areaOpacity: 0.14)
                .frame(height: 20)
                .opacity(pts.isEmpty ? 0 : (ctx.stale ? 0.5 : 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.label) \(c.value == "—" ? "unavailable" : c.value + " " + c.unit)")
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
            if let game = ctx.live.displayGame, ctx.live.online {
                PcCardHeader(title: widget.style.label ?? "Playing now", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget))
                gameTitle(PcGameStore.shared.game(ctx.live.game), game)
                PcFlow(spacing: 22, lineSpacing: 12) {
                    stat(ctx.live.values["fps"].map { PcFormat.number($0, unit: "fps") }, "fps")
                    stat(ctx.live.values["fps.low1"].map { PcFormat.number($0, unit: "fps") }, "1% low")
                    stat(ctx.live.values["power.total"].map { PcFormat.compact($0, unit: "W") }, "PC (est.)")
                }
                .padding(.top, 14)
            } else if let s = ctx.latestSession {
                PcCardHeader(title: widget.style.label ?? "Last session", symbol: PcLook.symbol(widget), tint: PcLook.tint(widget),
                             context: s.start.formatted(.relative(presentation: .named)))
                gameTitle(PcGameStore.shared.game(s.exe), s.name(games: PcGameStore.shared.games))
                PcFlow(spacing: 22, lineSpacing: 12) {
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

    private func gameTitle(_ game: PcGame?, _ name: String) -> some View {
        HStack(spacing: 10) {
            PcGameIcon(game: game, size: 32)
            Text(name).font(.system(size: 22, weight: .semibold)).foregroundStyle(PcLook.primary).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, 10)
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(PcLook.primary)
                .monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(PcLook.secondary)
        }
        .lineLimit(1)
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
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(PcLook.track).frame(height: 8)
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
