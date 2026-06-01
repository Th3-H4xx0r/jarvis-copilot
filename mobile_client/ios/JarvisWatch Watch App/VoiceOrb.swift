import SwiftUI

/// Animated JARVIS voice orb — a glassy globe with flowing translucent light
/// ribbons sweeping around a dark hollow interior, plus a soft fresnel rim. A
/// SwiftUI-Canvas port of the mobile orb so the watch matches the phone.
///
/// Each ribbon is a wavy loop on a unit sphere, tilted in 3D and orthographically
/// projected, drawn as a filled band whose half-width grows toward the viewer
/// (depth) so it reads as a folding sheet. Ribbons are drawn back-to-front and
/// composited additively (.plusLighter) on the dark backdrop. The tilts drift on
/// slow, incommensurate sinusoids for organic motion; `mode` sets palette + pace.
///
/// No mic amplitude on the watch (dictation, not streaming), so reactivity is
/// time-driven: speaking pulses, thinking churns, idle slowly wanders.
struct VoiceOrb: View {
    enum Mode: Equatable { case idle, thinking, speaking, error }
    var mode: Mode
    var size: CGFloat = 96

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { context, sz in
                var ctx = context
                Self.draw(&ctx, size: sz, mode: mode,
                          t: tl.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: palette

    private struct RGB {
        var r, g, b: Double
        func opacity(_ a: Double) -> Color { Color(red: r, green: g, blue: b).opacity(a) }
        static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
            RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
        }
    }
    private static let white = RGB(r: 1, g: 1, b: 1)

    // [highlight, core, accent]
    private static func palette(_ m: Mode) -> (RGB, RGB, RGB) {
        switch m {
        case .idle:
            return (RGB(r: 0.56, g: 0.85, b: 1.0), RGB(r: 0.23, g: 0.52, b: 1.0),
                    RGB(r: 0.49, g: 0.36, b: 1.0))
        case .thinking:
            return (RGB(r: 0.75, g: 0.66, b: 1.0), RGB(r: 0.42, g: 0.36, b: 1.0),
                    RGB(r: 0.61, g: 0.55, b: 1.0))
        case .speaking:
            return (RGB(r: 0.62, g: 0.88, b: 1.0), RGB(r: 0.23, g: 0.52, b: 1.0),
                    RGB(r: 0.49, g: 0.36, b: 1.0))
        case .error:
            return (RGB(r: 1.0, g: 0.69, b: 0.73), RGB(r: 1.0, g: 0.42, b: 0.49),
                    RGB(r: 1.0, g: 0.60, b: 0.65))
        }
    }

    // MARK: ribbon model

    private struct Built { var pts: [CGPoint]; var depth: [Double]; var meanFront: Double }
    private static let m = 64
    // (amp, k, phase, rx, ry, rz)
    private static let strands: [(Double, Double, Double, Double, Double, Double)] = [
        (0.20, 2, 0.0, 0.55, 0.30, 0.15),
        (0.26, 2, 2.1, 0.72, 0.58, 0.10),
        (0.18, 1, 4.2, 0.42, 0.85, 0.22),
    ]

    // MARK: draw

    private static func draw(_ ctx: inout GraphicsContext, size sz: CGSize, mode: Mode, t: Double) {
        let R = min(sz.width, sz.height) / 2
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let (hi, core, accent) = palette(mode)

        let breath = 0.5 + 0.5 * sin(t * 0.9)
        let talk = 0.5 + 0.5 * sin(t * 3.4)
        var reactive = 0.0, spinSpeed = 0.07, energy = 0.34
        switch mode {
        case .speaking: reactive = 0.30 + 0.40 * talk; spinSpeed = 0.12; energy = 0.55
        case .thinking: reactive = 0.12; spinSpeed = 0.15; energy = 0.58
        case .idle: reactive = 0.05 * breath; spinSpeed = 0.07; energy = 0.40
        case .error: reactive = 0.0; spinSpeed = 0.05; energy = 0.34
        }
        let wander = 0.18 * sin(t * 0.075) + 0.12 * sin(t * 0.117 + 2.1)
        let gt = t * spinSpeed + wander
        let undu = t * (0.32 + 0.25 * reactive)
        let scale = 1.0 + 0.025 * breath + 0.30 * reactive
        let rs = R * 0.46 * scale
        let bright = min(0.80 + 0.28 * energy + 0.34 * reactive, 1.45)

        ctx.blendMode = .plusLighter // everything glows additively on the dark bg

        // halo
        let haloR = rs * (1.5 + 0.25 * reactive)
        ctx.fill(
            Path(ellipseIn: CGRect(x: c.x - haloR, y: c.y - haloR, width: haloR * 2, height: haloR * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(0.22 * bright), location: 0),
                    .init(color: accent.opacity(0.10 * bright), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: c, startRadius: 0, endRadius: haloR))

        // ribbons, back → front
        var built = strands.map { build($0, c: c, rs: rs, gt: gt, undu: undu, t: t) }
        built.sort { $0.meanFront < $1.meanFront }

        let sheetCol = RGB.mix(core, hi, 0.4)
        let edgeCol = RGB.mix(hi, white, 0.5)
        let halfBase = rs * 0.17 * (1.0 + 0.40 * reactive)

        for b in built {
            let band = ribbonPath(b, halfBase: halfBase)
            // translucent sheet (soft via a single blurred layer — keeps the
            // watch render light vs the phone's multi-pass glow).
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: rs * 0.05))
                l.fill(band, with: .color(sheetCol.opacity(min((0.26 + 0.18 * b.meanFront) * bright, 0.72))))
            }
            // bright edge — front brighter than the part seen through the glass.
            let (front, back) = edgePaths(b)
            ctx.stroke(back, with: .color(edgeCol.opacity(min(0.22 * bright, 0.5))),
                       lineWidth: rs * 0.014)
            ctx.stroke(front, with: .color(edgeCol.opacity(min(0.55 * bright, 0.85))),
                       lineWidth: rs * 0.018)
        }

        // fresnel rim
        let rimCol = RGB.mix(core, white, 0.5)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: rs * 0.05))
            l.stroke(
                Path(ellipseIn: CGRect(x: c.x - rs, y: c.y - rs, width: rs * 2, height: rs * 2)),
                with: .color(rimCol.opacity(min(0.42 * bright, 0.7))), lineWidth: rs * 0.035)
        }
    }

    /// Wavy loop on a unit sphere → 3D tilt (with slow per-ribbon wander) → project.
    private static func build(_ s: (Double, Double, Double, Double, Double, Double),
                              c: CGPoint, rs: CGFloat, gt: Double, undu: Double, t: Double) -> Built {
        let amp = s.0, k = s.1, phase = s.2
        let rx = s.3 + 0.16 * sin(t * 0.050 + phase)
        let ry = s.4 + 0.14 * sin(t * 0.041 + phase * 1.7 + 1.0)
        let rz = s.5 + 0.11 * sin(t * 0.033 + phase * 0.7 + 2.0)
        let cx = cos(rx), sx = sin(rx), cy = cos(ry), sy = sin(ry), cz = cos(rz), sz = sin(rz)
        var pts = [CGPoint](); pts.reserveCapacity(m)
        var depth = [Double](); depth.reserveCapacity(m)
        var sumFront = 0.0
        for i in 0..<m {
            let u = Double(i) / Double(m) * 2 * .pi
            let theta = .pi / 2 + amp * sin(k * u + phase + undu)
            let phi = u + gt
            var x = sin(theta) * cos(phi)
            var y = sin(theta) * sin(phi)
            var z = cos(theta)
            let y1 = y * cx - z * sx, z1 = y * sx + z * cx; y = y1; z = z1 // Rx
            let x1 = x * cy + z * sy, z2 = -x * sy + z * cy; x = x1; z = z2 // Ry
            let x2 = x * cz - y * sz, y2 = x * sz + y * cz; x = x2; y = y2 // Rz
            pts.append(CGPoint(x: c.x + rs * x, y: c.y - rs * y))
            depth.append(z)
            sumFront += (z + 1) / 2
        }
        return Built(pts: pts, depth: depth, meanFront: sumFront / Double(m))
    }

    /// Filled band: offset the centerline ± a depth-scaled half-width.
    private static func ribbonPath(_ b: Built, halfBase: CGFloat) -> Path {
        let n = b.pts.count
        var left = [CGPoint](), right = [CGPoint]()
        for i in 0..<n {
            let p = b.pts[i]
            let pp = b.pts[(i - 1 + n) % n], pn = b.pts[(i + 1) % n]
            var tx = pn.x - pp.x, ty = pn.y - pp.y
            let len = max(hypot(tx, ty), 1e-6); tx /= len; ty /= len
            let nx = -ty, ny = tx
            let hw = halfBase * CGFloat(0.35 + 0.75 * ((b.depth[i] + 1) / 2))
            left.append(CGPoint(x: p.x + nx * hw, y: p.y + ny * hw))
            right.append(CGPoint(x: p.x - nx * hw, y: p.y - ny * hw))
        }
        var path = Path()
        path.move(to: left[0])
        for i in 1..<n { path.addLine(to: left[i]) }
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: right[i]) }
        path.closeSubpath()
        return path
    }

    /// Split the centerline into front (z≥0) / back polylines for depth shading.
    private static func edgePaths(_ b: Built) -> (Path, Path) {
        let n = b.pts.count
        var front = Path(), back = Path()
        var fOpen = false, bOpen = false
        for i in 0...n {
            let idx = i % n
            let p = b.pts[idx]
            if b.depth[idx] >= -0.05 {
                if !fOpen { front.move(to: p); fOpen = true } else { front.addLine(to: p) }
                bOpen = false
            } else {
                if !bOpen { back.move(to: p); bOpen = true } else { back.addLine(to: p) }
                fOpen = false
            }
        }
        return (front, back)
    }
}
