import AppIntents
import Charts
import Foundation
import SwiftUI
import WidgetKit

final class JCDesignRenderer {
    private var count = 0
    // Generous safety clamps (not a layout limit): the expanded island + lock
    // screen size to their content, so a rich design can fill the full available
    // height. These only guard against pathological/cyclic trees.
    private let maxDepth = 12
    private let maxNodes = 160
    let tint: Color

    init(tint: Color) { self.tint = tint }

    func render(_ node: JCNode?, _ ctx: JCBindingContext, depth: Int = 0) -> AnyView {
        guard let node = node, depth <= maxDepth, count < maxNodes else {
            return AnyView(EmptyView())
        }
        // `when` gating — skip a node (and its subtree) when its condition fails.
        if !jcEvalCondition(node.when, ctx) { return AnyView(EmptyView()) }
        count += 1
        let view = body(node, ctx, depth: depth)
        return AnyView(applyStyle(view, node.style, ctx))
    }

    @ViewBuilder
    private func body(_ n: JCNode, _ ctx: JCBindingContext, depth: Int) -> some View {
        switch n.type {
        // ── Containers ──────────────────────────────────────────────────────
        case "hstack":
            HStack(alignment: jcVAlign(n.string("align")), spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "vstack":
            VStack(alignment: jcHAlign(n.string("align")), spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "zstack":
            ZStack {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "grid":
            let cols = max(1, n.int("columns") ?? 2)
            let items = Array(repeating: GridItem(.flexible(), spacing: jcSpacing(n)),
                              count: cols)
            LazyVGrid(columns: items, spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "list":
            renderList(n, ctx, depth: depth)
        case "spacer":
            if let m = n.double("minLength") { Spacer(minLength: CGFloat(m)) } else { Spacer() }
        case "regions":
            // Outside the DI expanded region wiring (lock screen), flatten the
            // regions into a vertical stack so nothing is lost.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["leading", "trailing", "center", "bottom"], id: \.self) { key in
                    self.render(n.node(key), ctx, depth: depth + 1)
                }
            }
        // ── Leaves ──────────────────────────────────────────────────────────
        case "text":
            jcText(n.ref("value")?.string(ctx) ?? "", n, ctx)
                .lineLimit(n.int("lineLimit") ?? 1)
        case "titleSubtitle":
            VStack(alignment: .leading, spacing: 2) {
                jcText(n.ref("title")?.string(ctx) ?? "", n, ctx, size: 14, weight: .bold)
                    .lineLimit(1)
                jcText(n.ref("subtitle")?.string(ctx) ?? "", n, ctx,
                       size: 11, weight: .semibold, opacity: 0.6)
                    .lineLimit(1)
            }
        case "stat":
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                jcText(n.ref("value")?.string(ctx) ?? "—", n, ctx, size: 22, weight: .heavy)
                if let unit = n.ref("unit")?.string(ctx) {
                    jcText(unit, n, ctx, size: 11, weight: .semibold, opacity: 0.6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let cap = n.ref("caption")?.string(ctx) {
                    jcText(cap, n, ctx, size: 9, weight: .medium, opacity: 0.5)
                        .offset(y: 12)
                }
            }
        case "symbol":
            jcSymbol(n, ctx)
        case "symbolValue":
            HStack(spacing: 5) {
                if let name = n.ref("symbol")?.string(ctx) {
                    Image(systemName: name).font(.system(size: n.style?.size.map { CGFloat($0) } ?? 13))
                        .foregroundStyle(n.style?.color.flatMap(jcParseColor) ?? .white)
                }
                jcText(n.ref("value")?.string(ctx) ?? "", n, ctx, size: 13, weight: .semibold)
            }
        case "image":
            jcImage(n, ctx)
        case "dot":
            Circle()
                .fill(n.ref("color")?.color(ctx) ?? tint)
                .frame(width: 8, height: 8)
        case "badge":
            jcBadge(n, ctx)
        case "progress":
            jcProgress(n, ctx)
        case "segbar":
            jcSegbar(n, ctx)
        case "gauge":
            jcGauge(n, ctx)
        case "timer":
            jcTimer(n, ctx)
        case "timeProgress":
            jcTimeProgress(n, ctx)
        case "keyValue":
            jcKeyValue(n, ctx)
        case "sparkline":
            jcSparkline(n, ctx)
        case "iconStrip":
            jcIconStrip(n, ctx)
        case "waveform":
            jcWaveform(n)
        case "divider":
            Divider().overlay(Color.white.opacity(0.18))
        case "accent":
            RoundedRectangle(cornerRadius: 2)
                .fill(n.ref("color")?.color(ctx) ?? tint)
                .frame(width: 3)
        // ── Widget blocks ───────────────────────────────────────────────────
        case "chart":
            jcChart(n, ctx)
        case "model":
            jcModel(n, ctx)
        case "button":
            jcButton(n, ctx)
        case "toggle":
            jcToggle(n, ctx)
        default:
            // Unknown type → render nothing (forward-compat).
            EmptyView()
        }
    }

    // ── List ────────────────────────────────────────────────────────────────
    @ViewBuilder
    private func renderList(_ n: JCNode, _ ctx: JCBindingContext, depth: Int) -> some View {
        let rows = (n.ref("data")?.array(ctx) ?? []).compactMap { $0.asObject }
        let maxRows = max(0, min(n.int("max") ?? rows.count, rows.count))
        if rows.isEmpty {
            render(n.node("empty"), ctx, depth: depth + 1)
        } else if let cols = n.int("columns"), cols > 1 {
            let items = Array(repeating: GridItem(.flexible(), spacing: 6), count: cols)
            LazyVGrid(columns: items, alignment: .leading, spacing: 6) {
                ForEach(0..<maxRows, id: \.self) { i in
                    self.render(n.node("row"), ctx.withRow(rows[i]), depth: depth + 1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<maxRows, id: \.self) { i in
                    self.render(n.node("row"), ctx.withRow(rows[i]), depth: depth + 1)
                }
            }
        }
    }

    // ── Leaf builders ─────────────────────────────────────────────────────────
    private func jcText(_ s: String, _ n: JCNode, _ ctx: JCBindingContext,
                        size: CGFloat = 13, weight: Font.Weight = .medium,
                        opacity: Double = 1) -> some View {
        let sz = n.style?.size.map { CGFloat($0) } ?? size
        let w = n.style?.weight.flatMap(jcWeight) ?? weight
        let col = n.style?.color.flatMap(jcParseColor) ?? .white
        let op = n.style?.opacity ?? opacity
        return Text(s).font(.system(size: sz, weight: w)).foregroundStyle(col.opacity(op))
    }

    @ViewBuilder
    private func jcSymbol(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let name = n.ref("name")?.string(ctx) ?? n.string("name") ?? "questionmark"
        let sz = n.style?.size.map { CGFloat($0) } ?? 16
        let col = n.style?.color.flatMap(jcParseColor) ?? n.style?.tint.flatMap(jcParseColor) ?? .white
        let img = Image(systemName: name).font(.system(size: sz)).foregroundStyle(col)
        if let effect = n.string("effect") {
            switch effect {
            case "pulse": img.symbolEffect(.pulse, options: .repeating)
            case "bounce": img.symbolEffect(.bounce, options: .repeating)
            case "variableColor": img.symbolEffect(.variableColor, options: .repeating)
            default: img
            }
        } else {
            img
        }
    }

    @ViewBuilder
    private func jcImage(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // `source` may be:
        //   • the reserved "orb" → the shared JARVIS orb image,
        //   • a remote http(s) URL → rendered from the App Group cache the app
        //     pre-downloaded (the extension can't fetch at render time; until
        //     it's cached, `fallback` SF Symbol / a placeholder is shown),
        //   • otherwise an SF Symbol name.
        let source = n.ref("source")?.string(ctx) ?? n.string("source") ?? ""
        let fallback = n.ref("fallback")?.string(ctx) ?? n.string("fallback") ?? ""
        let w = n.style?.width.map { CGFloat($0) } ?? 28
        let h = n.style?.height.map { CGFloat($0) } ?? w
        let shape = n.string("shape") ?? "circle"
        let base: AnyView = {
            if source == "orb", let ui = jarvisOrbUIImage {
                return AnyView(Image(uiImage: ui).resizable().scaledToFill())
            }
            if source.hasPrefix("http") {
                if let file = JCImageCache.localFile(for: source),
                   let ui = UIImage(contentsOfFile: file.path) {
                    return AnyView(Image(uiImage: ui).resizable().scaledToFit())
                }
                if !fallback.isEmpty {
                    return AnyView(Image(systemName: fallback).resizable().scaledToFit()
                        .foregroundStyle(.white))
                }
                return AnyView(Rectangle().fill(Color.white.opacity(0.1)))
            }
            if !source.isEmpty {
                return AnyView(Image(systemName: source).resizable().scaledToFit()
                    .foregroundStyle(.white))
            }
            return AnyView(Rectangle().fill(Color.white.opacity(0.1)))
        }()
        base
            .frame(width: w, height: h)
            .clipShape(shape == "rounded"
                ? JCAnyShape(RoundedRectangle(cornerRadius: 6))
                : JCAnyShape(Circle()))
    }

    private func jcBadge(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let text = n.ref("text")?.string(ctx) ?? ""
        let c = n.ref("color")?.color(ctx) ?? tint
        return Text(text)
            .font(.system(size: 10, weight: .heavy)).tracking(0.5)
            .foregroundStyle(c)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(Capsule().fill(c.opacity(0.2)))
            .overlay(Capsule().stroke(c.opacity(0.45), lineWidth: 1))
    }

    // A configurable icon placed at the tip (fill edge) of a progress/segbar.
    // `symbol` is an SF Symbol so any shape works (airplane / circle.fill / arrow);
    // `color` defaults to the bar tint. See jcParseTip / jcTipView.
    private struct JCTip { let symbol: String; let color: Color?; let size: CGFloat; let rotation: Double }

    private func jcParseTip(_ n: JCNode, _ ctx: JCBindingContext) -> JCTip? {
        guard let raw = n.props["tip"] else { return nil }
        // string shorthand: "tip":"airplane" (a bare number/bool is NOT a symbol)
        if case .string(let s) = raw, !s.isEmpty {
            return JCTip(symbol: s, color: nil, size: 13, rotation: 0)
        }
        guard let o = raw.asObject,
              let sym = JCValueRef(o["symbol"] ?? .null).string(ctx), !sym.isEmpty
        else { return nil }
        let color = o["color"].map(JCValueRef.init)?.color(ctx)
        let size = CGFloat(o["size"]?.asDouble ?? 13)
        let rotation = o["rotation"]?.asDouble ?? 0
        return JCTip(symbol: sym, color: color, size: size, rotation: rotation)
    }

    private func jcTipView(_ tip: JCTip) -> some View {
        Image(systemName: tip.symbol)
            .font(.system(size: tip.size, weight: .semibold))
            .foregroundStyle(tip.color ?? tint)
            .rotationEffect(.degrees(tip.rotation))
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0.5)
    }

    // Center-x for the tip icon: the fill edge (width * fraction), clamped so the
    // icon stays fully on the bar at the extremes.
    private func jcTipX(_ width: CGFloat, _ frac: Double, _ size: CGFloat) -> CGFloat {
        let edge = width * CGFloat(jcClamp01(frac))
        return min(max(edge, size / 2), max(size / 2, width - size / 2))
    }

    // segbar tip position: explicit `progress` (0–1) wins, else elapsed fraction
    // of `from`→`to` (epoch/ISO), computed at render time. nil → no tip.
    private func jcSegbarFraction(_ n: JCNode, _ ctx: JCBindingContext) -> Double? {
        if let p = n.ref("progress")?.double(ctx) {
            return jcClamp01(p / jcScale(n))
        }
        if let from = jcParseDate(n.ref("from")?.resolve(ctx)),
           let to = jcParseDate(n.ref("to")?.resolve(ctx)), to > from {
            return jcClamp01(Date().timeIntervalSince(from) / to.timeIntervalSince(from))
        }
        return nil
    }

    private func jcProgress(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let v = jcClamp01((n.ref("value")?.double(ctx) ?? 0) / jcScale(n))
        let c = n.ref("tint")?.color(ctx) ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        let tip = jcParseTip(n, ctx)
        return GeometryReader { geo in
            ZStack {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(c).frame(width: geo.size.width * CGFloat(v))
                }
                .frame(height: 8)
                if let tip = tip {
                    self.jcTipView(tip)
                        .position(x: self.jcTipX(geo.size.width, v, tip.size),
                                  y: geo.size.height / 2)
                }
            }
        }
        .frame(height: max(8, tip?.size ?? 8))
    }

    private func jcSegbar(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let segs = (n.ref("segments")?.array(ctx) ?? []).compactMap { $0.asObject }
        let tip = jcParseTip(n, ctx)
        let frac = jcSegbarFraction(n, ctx)
        return GeometryReader { geo in
            ZStack {
                HStack(spacing: 2) {
                    if segs.isEmpty {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12)).frame(height: 8)
                    } else {
                        ForEach(jcIndexed(segs), id: \.0) { _, seg in
                            let weight = max(0.0001, seg["weight"]?.asDouble ?? 1)
                            let c = seg["color"]?.asString.flatMap(jcParseColor) ?? self.tint
                            RoundedRectangle(cornerRadius: 2).fill(c)
                                .frame(height: 8)
                                .frame(maxWidth: .infinity)
                                .layoutPriority(weight)
                        }
                    }
                }
                if let tip = tip, let frac = frac {
                    self.jcTipView(tip)
                        .position(x: self.jcTipX(geo.size.width, frac, tip.size),
                                  y: geo.size.height / 2)
                }
            }
        }
        .frame(height: max(8, tip?.size ?? 8))
    }

    @ViewBuilder
    private func jcGauge(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // style "single" → one ring; "concentric" → nested rings (both built from
        // the `rings:[{value,tint}]` prop, with a single-`value` fallback).
        let rings = gaugeRingsFromProps(n, ctx)
        let label = n.ref("label")?.string(ctx)
        ZStack {
            ForEach(jcIndexed(rings), id: \.0) { i, ring in
                let d: CGFloat = 46 - CGFloat(i) * 16
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 4).frame(width: d, height: d)
                Circle().trim(from: 0, to: CGFloat(jcClamp01(ring.value)))
                    .stroke(ring.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: d, height: d)
            }
            if let label = label {
                Text(label).font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
    }

    private struct GaugeRing { let value: Double; let tint: Color }
    private func gaugeRingsFromProps(_ n: JCNode, _ ctx: JCBindingContext) -> [GaugeRing] {
        // rings: [{value, tint}] — value 0..1 (or 0..100 with scale).
        let raw = n.props["rings"]?.asArray ?? []
        let scale = jcScale(n)
        let rings = raw.compactMap { item -> GaugeRing? in
            guard let o = item.asObject else { return nil }
            let val = JCValueRef(o["value"] ?? .null).double(ctx) ?? (o["value"]?.asDouble ?? 0)
            let tintC = o["tint"]?.asString.flatMap(jcParseColor) ?? tint
            return GaugeRing(value: val / scale, tint: tintC)
        }
        if rings.isEmpty {
            // single-style fallback: one ring from `value`.
            let v = (n.ref("value")?.double(ctx) ?? 0) / scale
            return [GaugeRing(value: v, tint: tint)]
        }
        return rings
    }

    @ViewBuilder
    private func jcTimer(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // `to` is epoch seconds (number) or an ISO string parsed to a Date. The
        // countdown/up runs ON-DEVICE (offline) — iOS drives these natively, no
        // code or network. `format:"relative"` → "5 days, 18 hr" (coarse, best
        // for multi-day); default → clock HH:MM:SS that ticks every second.
        let toRef = n.ref("to")
        let fmt = (n.string("format") ?? "").lowercased()
        let size = n.style?.size.map { CGFloat($0) } ?? 15
        let weight = n.style?.weight.flatMap(jcWeight) ?? .semibold
        let color = n.style?.color.flatMap(jcParseColor) ?? .white
        if let date = jcParseDate(toRef?.resolve(ctx)) {
            let countdown = (n.string("mode") ?? "countdown") == "countdown"
            if fmt == "relative" {
                // Human, self-updating ("in 5 days" magnitude → "23 min").
                Text(date, style: .relative)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color).monospacedDigit()
            } else {
                // CRITICAL: for a countdown the interval must END at the target
                // (now…date). The old `date…distantFuture` counted down to the
                // distant future → a giant bogus number that never moved. Build a
                // valid (lower ≤ upper) range; a past target collapses to 00:00.
                let now = Date()
                let range: ClosedRange<Date> = countdown
                    ? (now <= date ? now...date : date...now)
                    : (date <= now ? date...Date.distantFuture : now...Date.distantFuture)
                Text(timerInterval: range, countsDown: countdown)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color).monospacedDigit()
            }
        } else {
            Text("--:--").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4)).monospacedDigit()
        }
    }

    @ViewBuilder
    private func jcTimeProgress(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // A self-filling progress bar from `from`→`to` (epoch/ISO dates). Renders
        // OFFLINE with no code: ProgressView(timerInterval:) advances on its own,
        // so flight progress keeps moving with no network.
        let barTint = n.ref("tint")?.color(ctx)
            ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        if let from = jcParseDate(n.ref("from")?.resolve(ctx)),
           let to = jcParseDate(n.ref("to")?.resolve(ctx)), to > from {
            ProgressView(timerInterval: from...to, countsDown: false)
                .progressViewStyle(.linear)
                .tint(barTint)
                .labelsHidden()
        } else {
            ProgressView(value: 0.0)
                .progressViewStyle(.linear)
                .tint(barTint)
        }
    }

    private func jcKeyValue(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let pairs = (n.props["pairs"]?.asArray ?? []).compactMap { $0.asObject }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(jcIndexed(pairs), id: \.0) { _, p in
                HStack {
                    Text(JCValueRef(p["label"] ?? .null).string(ctx) ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 8)
                    Text(JCValueRef(p["value"] ?? .null).string(ctx) ?? "")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func jcSparkline(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let pts = (n.ref("points")?.array(ctx) ?? []).compactMap { $0.asDouble }
        let c = n.ref("tint")?.color(ctx) ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        let kind = n.string("kind") ?? "line"
        return JCSparklineShape(points: pts, filled: kind == "area")
            .stroke(c, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .background(
                kind == "area"
                    ? AnyView(JCSparklineShape(points: pts, filled: true)
                        .fill(c.opacity(0.18)))
                    : AnyView(EmptyView())
            )
            .frame(height: 22)
    }

    /// A Swift Charts line, bar or area chart over a series of numbers or `{x, y}` points.
    @ViewBuilder
    private func jcChart(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let points = JCChartPoint.points(from: n.ref("series")?.array(ctx) ?? [])
        let color = n.ref("color")?.color(ctx) ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        let style = n.string("style") ?? "line"
        let height = n.style?.height.map { CGFloat($0) } ?? 60
        if points.isEmpty {
            Text("—").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart(points) { point in
                switch style {
                case "bar":
                    BarMark(x: .value("x", point.label), y: .value("y", point.value))
                        .foregroundStyle(color)
                        .cornerRadius(3)
                case "area":
                    AreaMark(x: .value("x", point.label), y: .value("y", point.value))
                        .foregroundStyle(color.opacity(0.35))
                    LineMark(x: .value("x", point.label), y: .value("y", point.value))
                        .foregroundStyle(color)
                default:
                    LineMark(x: .value("x", point.label), y: .value("y", point.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: jcChartDomain(n, points))
            .chartXAxis(n.bool("axes") == true ? .automatic : .hidden)
            .chartYAxis(n.bool("axes") == true ? .automatic : .hidden)
            .frame(height: height)
        }
    }

    private func jcChartDomain(_ n: JCNode, _ points: [JCChartPoint]) -> ClosedRange<Double> {
        let low = n.double("min") ?? min(0, points.map(\.value).min() ?? 0)
        let high = n.double("max") ?? max(points.map(\.value).max() ?? 1, low + 1)
        return low...max(high, low + 1)
    }

    /// A wearable's 3D model, as the picture the app rendered of it.
    private func jcModel(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let device = n.ref("device")?.string(ctx) ?? n.string("device") ?? ""
        let w = n.style?.width.map { CGFloat($0) }
        let h = n.style?.height.map { CGFloat($0) } ?? w ?? 64
        return Group {
            if let image = WidgetImages.model(device) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: WidgetImages.symbol(device)).resizable().scaledToFit()
                    .foregroundStyle(.white.opacity(0.8)).padding(h * 0.15)
            }
        }
        .frame(width: w, height: h)
    }

    /// Runs a Jarvis button (set up in the app) without opening the app.
    @ViewBuilder
    private func jcButton(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let id = n.string("button") ?? ""
        let info = ControlButtonShelf.infos().first { $0.id == id }
        let label = n.ref("label")?.string(ctx) ?? info?.name ?? "Button"
        let symbol = n.string("symbol") ?? info?.symbol ?? "bolt.fill"
        let color = n.ref("color")?.color(ctx) ?? info?.tintColor ?? tint
        let face = Label(label, systemImage: symbol)
            .font(.system(size: n.style?.size.map { CGFloat($0) } ?? 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(color.opacity(info == nil ? 0.12 : 0.35), in: Capsule())
        if let info {
            Button(intent: RunJarvisButtonIntent(button: ControlButtonEntity(info))) { face }
                .buttonStyle(.plain)
        } else {
            face.opacity(0.5)
        }
    }

    /// A Jarvis switch: lit while on, flipping it runs the button in the app.
    @ViewBuilder
    private func jcToggle(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let id = n.string("button") ?? ""
        let info = ControlButtonShelf.infos().first { $0.id == id }
        let label = n.ref("label")?.string(ctx) ?? info?.name ?? "Switch"
        let on = info?.isOn ?? false
        let symbol = on ? (info?.symbol ?? "switch.2") : (info?.offSymbol ?? info?.symbol ?? "switch.2")
        let face = Label(label, systemImage: symbol)
            .font(.system(size: n.style?.size.map { CGFloat($0) } ?? 13, weight: .semibold))
            .lineLimit(1)
        if let info {
            Toggle(isOn: on, intent: SetJarvisButtonIntent(button: ControlButtonEntity(info))) { face }
                .toggleStyle(.switch)
                .tint(info.tintColor ?? tint)
                .foregroundStyle(.white)
        } else {
            face.foregroundStyle(.white).opacity(0.5)
        }
    }

    private func jcIconStrip(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let items = (n.ref("items")?.array(ctx) ?? []).compactMap { $0.asString }
        let maxN = n.int("max") ?? items.count
        let shown = Array(items.prefix(max(0, maxN)))
        return HStack(spacing: 12) {
            ForEach(jcIndexed(shown), id: \.0) { _, name in
                Image(systemName: name).font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if items.count > shown.count {
                Text("+\(items.count - shown.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func jcWaveform(_ n: JCNode) -> some View {
        // Static bars (a Live Activity can't drive a continuous custom animation);
        // reads as a "voice" affordance.
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(self.tint.opacity(0.8))
                    .frame(width: 3, height: [10.0, 18, 8, 22, 12, 16, 9][i % 7])
            }
        }
    }

    // ── Style application ─────────────────────────────────────────────────────
    @ViewBuilder
    private func applyStyle<V: View>(_ view: V, _ style: JCStyle?, _ ctx: JCBindingContext) -> some View {
        // Note: the expanded Dynamic Island is capped at ~144pt by iOS; minHeight
        // lets a content-light container fill toward that cap (nil = no-op).
        return view
            .padding(style?.padding.map { CGFloat($0) } ?? 0)
            .frame(width: style?.width.map { CGFloat($0) },
                   height: style?.height.map { CGFloat($0) })
            .frame(minHeight: style?.minHeight.map { CGFloat($0) }, alignment: .top)
            .opacity(style?.opacity ?? 1)
    }
}

// ── Small helpers ────────────────────────────────────────────────────────────

func jcIndexed<T>(_ items: [T]) -> [(Int, T)] { Array(items.enumerated()) }
func jcSpacing(_ n: JCNode) -> CGFloat { CGFloat(n.double("spacing") ?? 6) }
func jcScale(_ n: JCNode) -> Double {
    // progress/gauge values may be 0..1 or 0..100; `scale` (default 1) lets the
    // author say 100. Heuristic: if no scale given and value>1 looks like a pct.
    n.double("scale") ?? 1
}
func jcClamp01(_ v: Double) -> Double { max(0, min(1, v)) }

func jcHAlign(_ s: String?) -> HorizontalAlignment {
    switch s { case "center": return .center; case "trailing": return .trailing; default: return .leading }
}
func jcVAlign(_ s: String?) -> VerticalAlignment {
    switch s { case "top": return .top; case "bottom": return .bottom; case "firstBaseline": return .firstTextBaseline; default: return .center }
}
func jcWeight(_ s: String) -> Font.Weight {
    switch s {
    case "ultraLight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .regular
    }
}
func jcParseDate(_ v: JCJSON?) -> Date? {
    guard let v = v else { return nil }
    if let n = v.asDouble, n > 0 {
        // epoch seconds (>1e12 → ms)
        return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
    }
    if let s = v.asString {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
    }
    return nil
}

/// A line/area path for sparkline points, normalized to its frame.
struct JCSparklineShape: Shape {
    let points: [Double]
    let filled: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count > 1 else { return p }
        let lo = points.min() ?? 0, hi = points.max() ?? 1
        let span = hi - lo == 0 ? 1 : hi - lo
        let stepX = rect.width / CGFloat(points.count - 1)
        func pt(_ i: Int) -> CGPoint {
            let y = rect.height - CGFloat((points[i] - lo) / span) * rect.height
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
        p.move(to: pt(0))
        for i in 1..<points.count { p.addLine(to: pt(i)) }
        if filled {
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()
        }
        return p
    }
}

/// Type-erased Shape so a node can pick its clip shape at runtime. (Named JC* to
/// avoid shadowing SwiftUI's own iOS-16 `AnyShape` and any deployment ambiguity.)
struct JCAnyShape: Shape {
    private let pathFn: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { pathFn = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { pathFn(rect) }
}


// MARK: - Colours shared with the island views

func jcStateColor(_ s: String) -> Color {
    switch s {
    case "listening": return JcAccent.color                           // the app accent
    case "thinking":  return Color(red: 0.93, green: 0.94, blue: 0.97) // bright neutral, as in the app
    case "speaking":  return Color(red: 1.0,  green: 0.44, blue: 0.85) // pink
    case "error":     return Color(red: 1.0,  green: 0.42, blue: 0.49) // red
    default:          return JcAccent.soft                            // idle: the soft accent
    }
}

func jcCodingColor(_ s: String) -> Color {
    switch s {
    case "working": return Color(red: 0.20, green: 0.83, blue: 0.60)  // green
    case "waiting": return Color(red: 1.0,  green: 0.76, blue: 0.30)  // amber — as "waiting on you" in the app
    case "dim":     return Color(red: 0.40, green: 0.42, blue: 0.45)  // muted (forgotten)
    default:        return Color(red: 0.51, green: 0.55, blue: 0.59)  // grey (idle)
    }
}

let jcUsage5Color = Color(red: 0.98, green: 0.44, blue: 0.52)    // red
let jcUsageWeekColor = JcAccent.color



// MARK: - Widget block helpers

/// One point of a `chart`: a series item that is a number, or `{x, y}`.
struct JCChartPoint: Identifiable, Equatable {
    let id: Int
    let label: String
    let value: Double

    static func points(from items: [JCJSON]) -> [JCChartPoint] {
        items.enumerated().compactMap { index, item in
            if let value = item.asDouble, item.asObject == nil {
                if case .string = item { return nil }
                return JCChartPoint(id: index, label: String(index), value: value)
            }
            guard let object = item.asObject, let value = object["y"]?.asDouble else { return nil }
            return JCChartPoint(id: index, label: object["x"]?.asString ?? String(index), value: value)
        }
    }
}

/// Pictures the app prepares for widgets in the App Group (the extension can't render SceneKit).
enum WidgetImages {
    static func modelURL(_ device: String) -> URL? {
        guard !device.isEmpty, device.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: JarvisShared.appGroupID) else { return nil }
        return container.appendingPathComponent("widgets/models", isDirectory: true)
            .appendingPathComponent("\(device).png")
    }

    static func model(_ device: String) -> UIImage? {
        guard let url = modelURL(device) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// What stands in for a device's model until its picture exists.
    static func symbol(_ device: String) -> String {
        switch device {
        case "ring", "x5ring": return "circle.circle"
        case "glasses": return "eyeglasses"
        case "bottle": return "waterbottle"
        case "scale": return "scalemass"
        case "esp32": return "cpu"
        case "pod": return "circle.hexagongrid"
        default: return "sensor"
        }
    }
}
