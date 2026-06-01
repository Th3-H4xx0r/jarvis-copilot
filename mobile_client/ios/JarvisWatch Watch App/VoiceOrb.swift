import SwiftUI

/// Animated JARVIS voice orb — a glassy globe with flowing translucent light
/// ribbons sweeping around a dark hollow interior, plus a soft fresnel rim. A
/// SwiftUI-Canvas port of the mobile orb so the watch matches the phone.
///
/// Performance note (watchOS): per-shape Canvas blur filters
/// (`drawLayer { addFilter(.blur) }`) are far too expensive here — they tanked
/// the frame rate (jerky "fast spinning") and stalled the orb while the phone
/// streamed a reply ("freezes while thinking"). So this draws everything CRISP
/// and cheap (gradient + fills + strokes, additive) and softens with ONE
/// view-level `.blur` pass. Motion is gentle and time-driven per state.
struct VoiceOrb: View {
    enum Mode: Equatable { case idle, thinking, speaking, error }
    var mode: Mode
    var size: CGFloat = 96

    // Elapsed time from first appearance → small, monotonic `t` exactly like the
    // mobile Stopwatch (not the huge absolute reference date).
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { context, sz in
                var ctx = context
                Self.draw(&ctx, size: sz, mode: mode, t: tl.date.timeIntervalSince(start))
            }
            .frame(width: size, height: size)
            .blur(radius: size * 0.012) // light softening only — keep definition
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
    private static let m = 48 // points per loop (kept low for watch perf)
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

        let breath = 0.5 + 0.5 * sin(t * 0.8)
        let talk = 0.5 + 0.5 * sin(t * 3.0)
        // "Alive" comes from a PULSE (breathing) + UNDULATION (ribbons flowing),
        // with only a gentle spin — so it reads as working, never whirling. A
        // CONSTANT reactive looks frozen, so thinking/speaking oscillate it.
        let pulse = 0.5 + 0.5 * sin(t * 1.7) // ~3.7s breathing cycle
        var reactive = 0.0, spinSpeed = 0.03, energy = 0.34, unduRate = 0.14
        switch mode {
        case .speaking:
            reactive = 0.24 + 0.34 * talk; spinSpeed = 0.06; energy = 0.55; unduRate = 0.55
        case .thinking:
            // a clear, calm breathing pulse + visibly flowing ribbons (no whirl)
            reactive = 0.10 + 0.22 * pulse; spinSpeed = 0.11; energy = 0.58; unduRate = 0.55
        case .idle:
            reactive = 0.05 * breath; spinSpeed = 0.03; energy = 0.40; unduRate = 0.16
        case .error:
            reactive = 0.0; spinSpeed = 0.02; energy = 0.34; unduRate = 0.08
        }
        let wander = 0.10 * sin(t * 0.05) + 0.06 * sin(t * 0.09 + 2.1)
        let gt = t * spinSpeed + wander
        let undu = t * unduRate
        let scale = 1.0 + 0.025 * breath + 0.30 * reactive
        let rs = R * 0.50 * scale
        let bright = min(0.85 + 0.28 * energy + 0.34 * reactive, 1.5)

        ctx.blendMode = .plusLighter // everything glows additively on the dark bg

        // halo (cheap radial gradient — alpha fades to 0)
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

        // ribbons, back → front (filled band + bright edge; the view-level blur
        // softens them — no expensive per-shape Canvas blur).
        var built = strands.map { build($0, c: c, rs: rs, gt: gt, undu: undu, t: t) }
        built.sort { $0.meanFront < $1.meanFront }

        let sheetCol = RGB.mix(core, hi, 0.4)
        let edgeCol = RGB.mix(hi, white, 0.5)
        let halfBase = rs * 0.20 * (1.0 + 0.40 * reactive)

        for b in built {
            let band = ribbonPath(b, halfBase: halfBase)
            // translucent sheet (the broad ribbon body)
            ctx.fill(band, with: .color(sheetCol.opacity(min((0.26 + 0.18 * b.meanFront) * bright, 0.72))))
            // bright edge — front brighter than the part seen through the glass.
            let (front, back) = edgePaths(b)
            ctx.stroke(back, with: .color(edgeCol.opacity(min(0.26 * bright, 0.5))),
                       lineWidth: rs * 0.026)
            ctx.stroke(front, with: .color(edgeCol.opacity(min(0.65 * bright, 0.9))),
                       lineWidth: rs * 0.040)
        }

        // fresnel rim — layered strokes fake a soft glow without a blur filter:
        // a wide faint halo-ring under a bright thin ring.
        let rimCol = RGB.mix(core, white, 0.5)
        let rimRect = CGRect(x: c.x - rs, y: c.y - rs, width: rs * 2, height: rs * 2)
        ctx.stroke(Path(ellipseIn: rimRect),
                   with: .color(rimCol.opacity(min(0.20 * bright, 0.4))), lineWidth: rs * 0.12)
        ctx.stroke(Path(ellipseIn: rimRect),
                   with: .color(rimCol.opacity(min(0.55 * bright, 0.8))), lineWidth: rs * 0.045)
    }

    /// Wavy loop on a unit sphere → 3D tilt (slow per-ribbon wander) → project.
    private static func build(_ s: (Double, Double, Double, Double, Double, Double),
                              c: CGPoint, rs: CGFloat, gt: Double, undu: Double, t: Double) -> Built {
        let amp = s.0, k = s.1, phase = s.2
        let rx = s.3 + 0.11 * sin(t * 0.030 + phase)
        let ry = s.4 + 0.09 * sin(t * 0.024 + phase * 1.7 + 1.0)
        let rz = s.5 + 0.07 * sin(t * 0.019 + phase * 0.7 + 2.0)
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
