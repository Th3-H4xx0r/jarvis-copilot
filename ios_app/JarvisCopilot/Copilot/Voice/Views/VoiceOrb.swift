import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The voice orb — a glassy globe with flowing translucent light *ribbons*
/// sweeping around a dark hollow interior, plus a bright fresnel rim. Port of
/// `voice/voice_orb.dart`'s `CustomPainter` onto SwiftUI's `Canvas`.
///
/// How it reads as 3D silk on a 2D canvas:
///   • each ribbon is a wavy loop on a unit sphere (elevation oscillates as it
///     goes around), tilted in 3D and orthographically projected;
///   • it's drawn as a filled BAND — the centreline ± a half-width that GROWS
///     where the ribbon faces the viewer — so it reads as a sheet folding
///     through space;
///   • each ribbon = a soft wide glow + a brighter defined sheet + a bright edge
///     (the silk fold catching light); ribbons are drawn back-to-front so the
///     additive light layers correctly.
///
/// `state` drives the palette + motion, `amplitude` drives reactivity, and all of
/// that maths lives in ``VoiceOrbGeometry``. The dark interior is simply the
/// absence of light on the near-black backdrop.
struct VoiceOrb: View {
    let state: VoiceState
    /// 0..1 mic peak. Smoothed here with an attack/release envelope.
    let amplitude: Double
    var size: CGFloat = 248
    /// False freezes the ticker. Every tab lives forever in the shell, so an
    /// ungated 60 fps orb would repaint on every tab — see `orbTickerEnabled`.
    var animating: Bool = true

    @State private var envelope = VoiceOrbEnvelope()
    /// Time origin, so `t` starts near zero instead of at the epoch (where the
    /// doubles are large enough to lose precision in the sine terms).
    @State private var origin = Date()

    /// How much bigger the drawing surface is than the orb's layout box.
    ///
    /// `Canvas` clips to its own frame, and the halo blooms to ~1.36× the base
    /// radius when the voice is loud — at a 1:1 frame that clip showed up as a
    /// visible square around the orb. Flutter's `CustomPaint` has no such edge, so
    /// the canvas is oversized and then constrained back to `size` for layout (a
    /// SwiftUI `frame` positions without clipping).
    private static let bleed: CGFloat = 1.7

    var body: some View {
        TimelineView(.animation(paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSince(origin)
            Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
                draw(&context, canvasSize, t: t)
            }
            .frame(width: size * Self.bleed, height: size * Self.bleed)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Draw

    private func draw(_ context: inout GraphicsContext, _ canvasSize: CGSize, t: Double) {
        let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Divide the bleed back out so the orb draws at its declared `size`; the
        // extra surface is only headroom for the halo.
        let base = min(canvasSize.width, canvasSize.height) / 2 / Self.bleed
        guard base > 0 else { return }

        let palette = state.palette
        let highlight = palette[0], core = palette[1], accent = palette[3]

        let drive = VoiceOrbGeometry.micDrive(state: state, amplitude: amplitude)
        let amp = envelope.update(target: drive, t: t)
        let energy = VoiceOrbGeometry.energy(state: state, t: t)
        let reactive = VoiceOrbGeometry.reactive(state: state, amplitude: amp, t: t)
        let radius = VoiceOrbGeometry.radius(base: base, reactive: reactive, t: t)
        let bright = VoiceOrbGeometry.brightness(energy: energy, reactive: reactive)
        let spin = t * VoiceOrbGeometry.spinSpeed(state) + VoiceOrbGeometry.wander(t)
        let undulation = t * VoiceOrbGeometry.undulationRate(state)

        context.blendMode = .plusLighter

        // ── Outer halo (blooms outward with the voice) ─────────────────────
        let haloRadius = VoiceOrbGeometry.haloRadius(radius, reactive: reactive)
        let haloRect = CGRect(x: centre.x - haloRadius, y: centre.y - haloRadius,
                              width: haloRadius * 2, height: haloRadius * 2)
        context.fill(
            Path(ellipseIn: haloRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(clamp(0.20 * bright, 0.5)), location: 0),
                    .init(color: accent.opacity(clamp(0.08 * bright, 0.5)), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: centre, startRadius: 0, endRadius: haloRadius))

        // ── Sphere body: a dark-blue disc so the lattice reads as a solid globe ──
        let bodyRect = CGRect(x: centre.x - radius, y: centre.y - radius,
                              width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: bodyRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(clamp(0.10 * bright, 0.3)), location: 0),
                    .init(color: core.opacity(clamp(0.22 * bright, 0.45)), location: 0.80),
                    .init(color: highlight.opacity(clamp(0.16 * bright, 0.4)), location: 1),
                ]),
                center: centre, startRadius: 0, endRadius: radius))

        // ── Point lattice: a dotted wireframe globe turning with the spin ──
        drawLattice(&context, centre: centre, radius: radius, spin: spin * 0.6, t: t,
                    colour: blend(core, highlight, 0.55), bright: bright)

        // ── Ribbons, back to front so the additive light stacks correctly ──
        let built = VoiceOrbGeometry.strands
            .map { build($0, centre: centre, radius: radius, spin: spin, undulation: undulation, t: t) }
            .sorted { $0.meanFront < $1.meanFront }

        let sheetColour = blend(core, highlight, 0.4)
        let edgeColour = blend(highlight, .white, 0.5)
        let halfBase = VoiceOrbGeometry.ribbonHalfWidth(radius, reactive: reactive)

        for ribbon in built {
            let band = ribbonPath(ribbon, halfBase: halfBase * 1.35)

            // Soft wide glow (the ribbon's aura).
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.09))
                layer.fill(band, with: .color(core.opacity(
                    clamp((0.16 + 0.14 * ribbon.meanFront) * bright, 0.6))))
            }
            // Defined translucent sheet.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.022))
                layer.fill(band, with: .color(sheetColour.opacity(
                    clamp((0.22 + 0.16 * ribbon.meanFront) * bright, 0.7))))
            }
            // Bright edge — the silk fold catching light, split front/back so the
            // part seen THROUGH the glass stays dimmer.
            let (front, back) = edgePaths(ribbon)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.010))
                layer.stroke(back, with: .color(edgeColour.opacity(clamp(0.22 * bright, 0.5))),
                             style: StrokeStyle(lineWidth: radius * 0.012))
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.008))
                layer.stroke(front, with: .color(edgeColour.opacity(clamp(0.55 * bright, 0.85))),
                             style: StrokeStyle(lineWidth: radius * 0.016))
            }
        }

        // ── Fresnel rim: a soft bright ring at the sphere's edge ───────────
        let rimColour = blend(core, .white, 0.5)
        let rimRect = CGRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.05))
            layer.stroke(Path(ellipseIn: rimRect),
                         with: .color(rimColour.opacity(clamp(0.40 * bright, 0.7))),
                         style: StrokeStyle(lineWidth: radius * 0.03))
            // Top emphasis arc — brighter up top, as light from above would be.
            var arc = Path()
            arc.addArc(center: centre, radius: radius,
                       startAngle: .radians(.pi + 0.25), endAngle: .radians(2 * .pi - 0.25),
                       clockwise: false)
            layer.stroke(arc, with: .color(rimColour.opacity(clamp(0.38 * bright, 0.7))),
                         style: StrokeStyle(lineWidth: radius * 0.045, lineCap: .round))
        }
    }

    // MARK: - Point lattice

    private static let latRings = 22
    private static let lonPoints = 44

    /// Dots on a unit sphere (latitude rings × longitude points), rotated by the
    /// orb's spin about Y plus a slow tilt, orthographically projected. Only the
    /// front hemisphere is drawn, batched into three depth buckets so the whole
    /// lattice costs three fills per frame instead of a thousand.
    private func drawLattice(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                             spin: Double, t: Double, colour: Color, bright: Double) {
        let tilt = 0.42 + 0.10 * sin(t * 0.13)
        let (ct, st) = (cos(tilt), sin(tilt))
        let roll = 0.18 * sin(t * 0.07)
        let (cr, sr) = (cos(roll), sin(roll))
        let dot = max(0.6, radius * 0.0075)
        var near = Path(), mid = Path(), far = Path()

        for i in 1..<Self.latRings {
            let theta = Double(i) / Double(Self.latRings) * .pi
            let sinT = sin(theta), cosT = cos(theta)
            for j in 0..<Self.lonPoints {
                let phi = Double(j) / Double(Self.lonPoints) * 2 * .pi + spin
                var x = sinT * cos(phi)
                var y = cosT
                var z = sinT * sin(phi)
                // Tilt about X, then a slow roll about Z.
                let y1 = y * ct - z * st, z1 = y * st + z * ct
                y = y1; z = z1
                let x2 = x * cr - y * sr, y2 = x * sr + y * cr
                x = x2; y = y2
                guard z > -0.05 else { continue }
                let p = CGPoint(x: centre.x + radius * x, y: centre.y - radius * y)
                let r = CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)
                if z > 0.6 { near.addEllipse(in: r) } else if z > 0.25 { mid.addEllipse(in: r) } else { far.addEllipse(in: r) }
            }
        }
        context.fill(far, with: .color(colour.opacity(clamp(0.16 * bright, 0.35))))
        context.fill(mid, with: .color(colour.opacity(clamp(0.34 * bright, 0.6))))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: dot * 0.8))
            layer.fill(near, with: .color(colour.opacity(clamp(0.30 * bright, 0.5))))
        }
        context.fill(near, with: .color(blend(colour, .white, 0.35).opacity(clamp(0.62 * bright, 0.9))))
    }

    // MARK: - Ribbon construction

    private struct Built {
        var points: [CGPoint]
        var depth: [Double]
        /// 0 (back) .. 1 (front), averaged over the loop.
        var meanFront: Double
    }

    /// Generate one ribbon: a wavy loop on a unit sphere → 3D tilt → orthographic
    /// projection. Each ribbon's tilt also drifts on its own slow, incommensurate
    /// sinusoids (seeded off `phase`) so the bands keep reshaping — organic idle
    /// motion rather than a rigid rotating cage.
    private func build(_ strand: VoiceOrbGeometry.Strand, centre: CGPoint, radius: CGFloat,
                       spin: Double, undulation: Double, t: Double) -> Built {
        let rx = strand.rx + 0.16 * sin(t * 0.11 + strand.phase)
        let ry = strand.ry + 0.14 * sin(t * 0.090 + strand.phase * 1.7 + 1.0)
        let rz = strand.rz + 0.11 * sin(t * 0.070 + strand.phase * 0.7 + 2.0)
        let (cx, sx) = (cos(rx), sin(rx))
        let (cy, sy) = (cos(ry), sin(ry))
        let (cz, sz) = (cos(rz), sin(rz))

        let n = VoiceOrbGeometry.loopPoints
        var points = [CGPoint]()
        var depth = [Double]()
        points.reserveCapacity(n)
        depth.reserveCapacity(n)
        var sumFront = 0.0

        for i in 0..<n {
            let u = (Double(i) / Double(n)) * 2 * .pi
            let theta = .pi / 2 + strand.amp * sin(Double(strand.waves) * u + strand.phase + undulation)
            let phi = u + spin
            var x = sin(theta) * cos(phi)
            var y = sin(theta) * sin(phi)
            var z = cos(theta)
            // Rx
            let y1 = y * cx - z * sx, z1 = y * sx + z * cx
            y = y1; z = z1
            // Ry
            let x1 = x * cy + z * sy, z2 = -x * sy + z * cy
            x = x1; z = z2
            // Rz
            let x2 = x * cz - y * sz, y2 = x * sz + y * cz
            x = x2; y = y2

            points.append(CGPoint(x: centre.x + radius * x, y: centre.y - radius * y))
            depth.append(z)
            sumFront += (z + 1) / 2
        }
        return Built(points: points, depth: depth, meanFront: sumFront / Double(n))
    }

    /// Offset the centreline ± a half-width along the 2D normal; the half-width
    /// grows toward the front so the sheet "folds" in space.
    private func ribbonPath(_ built: Built, halfBase: CGFloat) -> Path {
        let n = built.points.count
        guard n > 2 else { return Path() }
        var left = [CGPoint](), right = [CGPoint]()
        left.reserveCapacity(n)
        right.reserveCapacity(n)

        for i in 0..<n {
            let p = built.points[i]
            let previous = built.points[(i - 1 + n) % n]
            let next = built.points[(i + 1) % n]
            var tx = next.x - previous.x, ty = next.y - previous.y
            let length = sqrt(tx * tx + ty * ty)
            if length > 1e-6 { tx /= length; ty /= length }
            let nx = -ty, ny = tx
            let front = (built.depth[i] + 1) / 2
            let halfWidth = halfBase * CGFloat(0.35 + 0.75 * front)
            left.append(CGPoint(x: p.x + nx * halfWidth, y: p.y + ny * halfWidth))
            right.append(CGPoint(x: p.x - nx * halfWidth, y: p.y - ny * halfWidth))
        }

        var path = Path()
        path.move(to: left[0])
        for i in 1..<n { path.addLine(to: left[i]) }
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: right[i]) }
        path.closeSubpath()
        return path
    }

    /// Split the centreline into front (z ≥ 0) and back polylines so the front
    /// edge can be drawn brighter than the part seen through the glass.
    private func edgePaths(_ built: Built) -> (front: Path, back: Path) {
        let n = built.points.count
        var front = Path(), back = Path()
        guard n > 1 else { return (front, back) }
        var frontOpen = false, backOpen = false

        for i in 0...n {
            let index = i % n
            let point = built.points[index]
            if built.depth[index] >= -0.05 {
                if frontOpen { front.addLine(to: point) } else { front.move(to: point); frontOpen = true }
                backOpen = false
            } else {
                if backOpen { back.addLine(to: point) } else { back.move(to: point); backOpen = true }
                frontOpen = false
            }
        }
        return (front, back)
    }

    // MARK: - Small helpers

    private func clamp(_ value: Double, _ upper: Double) -> Double {
        min(max(value, 0), upper)
    }

    /// `Color.mix` is iOS 18+; this project deploys to 17.
    private func blend(_ a: Color, _ b: Color, _ amount: Double) -> Color {
        let ac = UIColor(a), bc = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ac.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        bc.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(min(max(amount, 0), 1))
        return Color(.sRGB,
                     red: Double(ar + (br - ar) * f),
                     green: Double(ag + (bg - ag) * f),
                     blue: Double(ab + (bb - ab) * f),
                     opacity: Double(aa + (ba - aa) * f))
    }
}
