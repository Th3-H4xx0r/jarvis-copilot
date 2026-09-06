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
            let drive = VoiceOrbGeometry.micDrive(state: state, amplitude: amplitude)
            let amp = envelope.update(target: drive, t: t)
            let energy = VoiceOrbGeometry.energy(state: state, t: t)
            let reactive = VoiceOrbGeometry.reactive(state: state, amplitude: amp, t: t)
            let bright = VoiceOrbGeometry.brightness(energy: energy, reactive: reactive)
            let side = size * Self.bleed
            ZStack {
                // The glass body: rendered per pixel by OrbShader.metal (liquidOrb).
                Rectangle()
                    .fill(Color.white)
                    .colorEffect(ShaderLibrary.liquidOrb(
                        .float2(side, side), .float(t), .float(bright),
                        .color(state.palette[1]), .color(state.palette[0]),
                        .color(blend(state.palette[0], .white, 0.6))))
                // Halo and dust stay on the Canvas above the glass.
                Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
                    draw(&context, canvasSize, t: t, amp: amp)
                }
            }
            .frame(width: side, height: side)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Draw

    private func draw(_ context: inout GraphicsContext, _ canvasSize: CGSize, t: Double, amp: Double) {
        let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Divide the bleed back out so the orb draws at its declared `size`; the
        // extra surface is only headroom for the halo.
        let base = min(canvasSize.width, canvasSize.height) / 2 / Self.bleed
        guard base > 0 else { return }

        let palette = state.palette
        let highlight = palette[0], core = palette[1], accent = palette[3]

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

        // ── Dust blown off the rim (the glass itself is the Metal layer below) ──
        drawDust(&context, centre: centre, radius: radius, t: t,
                 colour: Color(red: 0.35, green: 0.45, blue: 1.00), bright: bright)
        _ = (spin, undulation, highlight, accent)

    }

    // MARK: - Blob outline

    /// The sphere's outline as a slowly wobbling blob: a circle displaced by three
    /// low-frequency harmonics that drift in time, so the body reads as liquid
    /// rather than a rigid ball. Used for the fill, every clip, and the rims.
    private func blobPath(centre: CGPoint, radius: CGFloat, t: Double, wobble k: Double = 1.0) -> Path {
        var path = Path()
        let n = 120
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let wobble = 1.0
                + k * 0.030 * sin(3 * a + t * 0.70)
                + k * 0.022 * sin(5 * a - t * 0.45 + 1.3)
                + k * 0.018 * sin(2 * a + t * 0.30 + 2.1)
                + k * 0.012 * sin(7 * a + t * 0.9 + 0.4)
            let r = radius * CGFloat(wobble)
            let p = CGPoint(x: centre.x + r * CGFloat(cos(a)), y: centre.y + r * CGFloat(sin(a)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Ridges, scatter, orbits

    /// Thin latitude lines across the sphere — the fine "contour" texture of the
    /// reference — drawn as ellipses whose height compresses toward the poles.
    private func drawRidges(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                            t: Double, bright: Double) {
        let sphere = blobPath(centre: centre, radius: radius, t: t)
        context.drawLayer { layer in
            layer.clip(to: sphere)
            var lines = Path()
            let n = 26
            let drift = CGFloat(sin(t * 0.35)) * radius * 0.02
            for i in 1..<n {
                let f = CGFloat(i) / CGFloat(n)            // 0..1 top→bottom
                let y = centre.y - radius + f * radius * 2 + drift
                let halfW = radius * sqrt(max(0, 1 - pow(2 * f - 1, 2)))
                lines.move(to: CGPoint(x: centre.x - halfW, y: y))
                lines.addLine(to: CGPoint(x: centre.x + halfW, y: y))
            }
            layer.stroke(lines, with: .color(Color.white.opacity(clamp(0.09 * bright, 0.14))),
                         style: StrokeStyle(lineWidth: max(0.5, radius * 0.006)))
        }
    }

    /// Fine particle JETS: a handful of emitters on the rim each spray a cone of
    /// dots outward — dense at the surface, thinning with distance — like dust
    /// blown off the edge. Emitters drift slowly around the blob.
    private func drawDust(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                          t: Double, colour: Color, bright: Double) {
        var seed: UInt32 = 0x2545F491
        func rnd() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        let dot = max(0.45, radius * 0.0045)
        var near = Path(), far = Path()
        let emitters = 6
        for e in 0..<emitters {
            let base = Double(e) / Double(emitters) * 2 * .pi + 0.9 * sin(t * 0.06 + Double(e))
            let jetLength = 0.35 + 0.25 * rnd()
            let cone = 0.35 + 0.25 * rnd()
            for _ in 0..<70 {
                let d = pow(rnd(), 1.8) * jetLength
                let a = base + (rnd() - 0.5) * cone * (0.4 + d)
                let r = radius * CGFloat(1.0 + d)
                let x = centre.x + r * CGFloat(cos(a)), y = centre.y + r * CGFloat(sin(a))
                let rect = CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)
                if d < 0.12 { near.addEllipse(in: rect) } else { far.addEllipse(in: rect) }
            }
        }
        context.fill(far, with: .color(colour.opacity(clamp(0.40 * bright, 0.55))))
        context.fill(near, with: .color(blend(colour, .white, 0.3).opacity(clamp(0.65 * bright, 0.8))))
    }

    /// A deterministic cloud of tiny dots hugging the sphere's edge, slowly
    /// rotating, densest at the surface and thinning outward.
    private func drawScatter(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                             t: Double, colour: Color, bright: Double) {
        var dots = Path()
        var seed: UInt32 = 0x9E3779B9
        func rnd() -> Double {                       // small LCG, stable per frame
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        let dot = max(0.5, radius * 0.006)
        for _ in 0..<150 {
            let a = rnd() * 2 * .pi + t * 0.05
            let d = 1.0 + pow(rnd(), 2.2) * 0.32           // 1.00r .. 1.32r, dense near the edge
            let jitter = 0.97 + rnd() * 0.06
            let x = centre.x + radius * CGFloat(d * jitter * cos(a))
            let y = centre.y + radius * CGFloat(d * jitter * sin(a))
            dots.addEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
        }
        context.fill(dots, with: .color(colour.opacity(clamp(0.30 * bright, 0.4))))
    }

    /// Hairline concentric rings well outside the sphere, each carrying one short
    /// bright arc that sweeps around at its own rate.
    private func drawOrbits(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat,
                            t: Double, ring: Color, arc: Color, bright: Double) {
        let radii: [CGFloat] = [1.42, 1.62, 1.84]
        let hair = max(0.5, radius * 0.005)
        for (i, k) in radii.enumerated() {
            let r = radius * k
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                           with: .color(ring.opacity(0.10)), style: StrokeStyle(lineWidth: hair))
            let start = Angle.radians(t * (0.35 - Double(i) * 0.09) * (i % 2 == 0 ? 1 : -1) + Double(i) * 2.1)
            var sweep = Path()
            sweep.addArc(center: centre, radius: r, startAngle: start,
                         endAngle: start + .degrees(28 + Double(i) * 10), clockwise: false)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: hair * 2))
                layer.stroke(sweep, with: .color(arc.opacity(clamp(0.9 * bright, 1))),
                             style: StrokeStyle(lineWidth: hair * 2.4, lineCap: .round))
            }
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
