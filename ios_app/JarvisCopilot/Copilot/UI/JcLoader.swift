import SwiftUI

// JcLoader — the one Jarvis loading indicator, in place of every indeterminate
// `ProgressView`. It is drawn from the Jarvis logo: two identical elliptical rings
// crossing in an X (24×24 grid, centre 12,12, rx 9.6, ry 4.2, tilted −38° / +38°).
//
//   JcLoader()                      the app-wide default style, ≈20 pt (or the
//                                   environment's .controlSize: mini 12, small 16,
//                                   regular 20, large 28)
//   JcLoader(size: 14)              an explicit size
//   JcLoader(style: .draw)          a specific style (setup / first run / long waits)
//   JcLoader("Loading…")            with a caption under it, like ProgressView("…")
//
// It has no background and strokes in the environment's foreground style (like
// CSS currentColor), so colour it with `.foregroundStyle(...)` — `.tint` does NOT
// reach it.
//
// CHANGING THE LOOK
//   * App-wide: change `JcLoaderStyle.default` below. That one line moves every
//     plain `JcLoader()` on the iPhone, the Mac app and the Mac voice dylib.
//   * Adding a style: add a case to `JcLoaderStyle`, write a small renderer enum
//     next to `JcLoaderTrace` / `JcLoaderDraw` (a `period` and a
//     `render(in:size:phase:)`), and add it to the two switches in
//     `JcLoaderStyle`. Nothing else changes.
//
// ONE FILE, THREE BUILDS: this file is compiled into the iPhone app (here), the Mac
// app (mac_app/JarvisMac/project.yml lists this path) and the Mac voice dylib
// (mac_app/Sources/JarvisVoiceUI/Shared/JcLoader.swift is a symlink to it). Keep it
// plain SwiftUI — no UIKit/AppKit, no app types. The web's loader (webui/) draws the
// same two styles from the same SVG geometry; keep them in step.
//
// Reduce Motion: the same drawing at a quarter of the speed (4× the period), so it
// still reads as "working" without busy motion.

// MARK: - Style

enum JcLoaderStyle: CaseIterable, Sendable {
    /// Both rings faint; a bright quarter-ish segment runs round each ring, the two
    /// in opposite directions. The thinking / general spinner.
    case trace
    /// Each ring draws itself, holds, then erases; ring B a beat behind ring A.
    /// For setup, first run and longer waits.
    case draw

    /// The app-wide look of a plain `JcLoader()`. Change this one line to restyle
    /// every loader in the iPhone and Mac apps.
    static let `default`: JcLoaderStyle = .trace

    /// Seconds per loop at normal speed.
    var period: Double {
        switch self {
        case .trace: return JcLoaderTrace.period
        case .draw: return JcLoaderDraw.period
        }
    }

    /// Draws one frame. `phase` is the position in the loop, 0..<1.
    func render(in context: inout GraphicsContext, size: CGFloat, phase: Double) {
        switch self {
        case .trace: JcLoaderTrace.render(in: &context, size: size, phase: phase)
        case .draw: JcLoaderDraw.render(in: &context, size: size, phase: phase)
        }
    }
}

// MARK: - View

struct JcLoader: View {
    private let explicitSize: CGFloat?
    private let style: JcLoaderStyle
    private let label: String?

    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    /// `size` is the square's side in points; nil follows `.controlSize`.
    init(size: CGFloat? = nil, style: JcLoaderStyle = .default) {
        self.explicitSize = size
        self.style = style
        self.label = nil
    }

    /// The loader with a caption under it — the `ProgressView("Loading…")` form.
    init(_ label: String, size: CGFloat? = nil, style: JcLoaderStyle = .default) {
        self.explicitSize = size
        self.style = style
        self.label = label
    }

    private var side: CGFloat {
        if let explicitSize { return explicitSize }
        switch controlSize {
        case .mini: return 12
        case .small: return 16
        case .large: return 28
        default: return 20
        }
    }

    var body: some View {
        if let label {
            VStack(spacing: 8) {
                rings
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
        } else {
            rings
                .accessibilityElement()
                .accessibilityLabel(Text("Loading"))
        }
    }

    private var rings: some View {
        let side = side
        let style = style
        let period = style.period * (reduceMotion ? 4 : 1)
        // Paused while off screen or with the app in the background: no frames are
        // drawn for a loader nobody can see. Only the Canvas redraws per frame — the
        // frame is fixed, so there is never any layout work.
        return TimelineView(.animation(paused: !visible || scenePhase == .background)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                style.render(in: &context, size: side, phase: (t / period).truncatingRemainder(dividingBy: 1))
            }
        }
        .frame(width: side, height: side)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

/// One still frame of a loader — what `JcLoader` draws at `phase` (0..<1). For
/// render tests and any place that wants a fixed glyph.
struct JcLoaderFrame: View {
    var size: CGFloat = 20
    var style: JcLoaderStyle = .default
    var phase: Double

    var body: some View {
        Canvas { context, _ in style.render(in: &context, size: size, phase: phase) }
            .frame(width: size, height: size)
    }
}

// MARK: - Geometry (shared by every style)

enum JcLoaderGeometry {
    /// The logo's ring on the 24 grid: SVG "M2.4 12a9.6 4.2 0 1 0 19.2 0a9.6 4.2 0 1 0-19.2 0"
    /// — starts at the left end and runs left → bottom → right → top, so trims and
    /// directions match the web's `pathLength=100` dashes exactly.
    private static func ring(rotatedBy degrees: Double) -> Path {
        let cx = 12.0, cy = 12.0, rx = 9.6, ry = 4.2
        let k = 0.5522847498   // cubic Bézier circle constant
        var p = Path()
        p.move(to: CGPoint(x: cx - rx, y: cy))
        p.addCurve(to: CGPoint(x: cx, y: cy + ry),
                   control1: CGPoint(x: cx - rx, y: cy + k * ry), control2: CGPoint(x: cx - k * rx, y: cy + ry))
        p.addCurve(to: CGPoint(x: cx + rx, y: cy),
                   control1: CGPoint(x: cx + k * rx, y: cy + ry), control2: CGPoint(x: cx + rx, y: cy + k * ry))
        p.addCurve(to: CGPoint(x: cx, y: cy - ry),
                   control1: CGPoint(x: cx + rx, y: cy - k * ry), control2: CGPoint(x: cx + k * rx, y: cy - ry))
        p.addCurve(to: CGPoint(x: cx - rx, y: cy),
                   control1: CGPoint(x: cx - k * rx, y: cy - ry), control2: CGPoint(x: cx - rx, y: cy - k * ry))
        // SVG rotate(a 12 12): positive turns clockwise on screen, as here (y down).
        let turn = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -cx, y: -cy)
        return p.applying(turn)
    }

    /// Ring A, rotate(−38 12 12).
    static let ringA = ring(rotatedBy: -38)
    /// Ring B, rotate(38 12 12).
    static let ringB = ring(rotatedBy: 38)

    /// A ring scaled from the 24 grid to `size` points.
    static func scaled(_ ring: Path, to size: CGFloat) -> Path {
        ring.applying(CGAffineTransform(scaleX: size / 24, y: size / 24))
    }

    /// 1.6 on the 24 grid, never thinner than 1.2 pt; round caps.
    static func stroke(for size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(1.2, 1.6 * size / 24), lineCap: .round, lineJoin: .round)
    }

    /// The part of `ring` from `start` covering `length` (fractions of its length),
    /// wrapping across the path's start point as two trims.
    static func segment(of ring: Path, start: Double, length: Double) -> Path {
        let s = start - start.rounded(.down)
        let e = s + length
        if e <= 1 { return ring.trimmedPath(from: s, to: e) }
        var p = ring.trimmedPath(from: s, to: 1)
        p.addPath(ring.trimmedPath(from: 0, to: e - 1))
        return p
    }

    /// CSS/SVG cubic-bezier(x1, y1, x2, y2) easing at progress `x` (0...1).
    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        // Solve bez_x(t) = x by bisection — monotonic for 0 ≤ x1, x2 ≤ 1; 24 steps
        // is well under a pixel at any loader size.
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            if bez(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return bez(t, y1, y2)
    }
}

// MARK: - Trace

/// Both rings faint (opacity 0.22); a bright segment 26% of a ring's length runs
/// round each — ring A forwards along its path, ring B backwards — every 1.5 s,
/// linear. (SVG: dasharray "26 74", dashoffset 100→0 on A and 0→100 on B.)
enum JcLoaderTrace {
    static let period = 1.5
    static let segmentLength = 0.26
    static let faintOpacity = 0.22

    static func render(in context: inout GraphicsContext, size: CGFloat, phase: Double) {
        let a = JcLoaderGeometry.scaled(JcLoaderGeometry.ringA, to: size)
        let b = JcLoaderGeometry.scaled(JcLoaderGeometry.ringB, to: size)
        let stroke = JcLoaderGeometry.stroke(for: size)

        var faint = context
        faint.opacity = faintOpacity
        faint.stroke(a, with: .foreground, style: stroke)
        faint.stroke(b, with: .foreground, style: stroke)

        context.stroke(JcLoaderGeometry.segment(of: a, start: phase, length: segmentLength),
                       with: .foreground, style: stroke)
        context.stroke(JcLoaderGeometry.segment(of: b, start: 1 - phase, length: segmentLength),
                       with: .foreground, style: stroke)
    }
}

// MARK: - Draw

/// Ring A draws itself over 0–42% of a 2.6 s loop, holds to 60%, then erases (its
/// start moves 0 → 1) to 100%. Ring B is hidden to 12%, draws 12–50%, holds to 66%,
/// erases to 100%. The moving parts ease with cubic-bezier(.65, 0, .35, 1).
enum JcLoaderDraw {
    static let period = 2.6

    private static func ease(_ x: Double) -> Double {
        JcLoaderGeometry.cubicBezier(x, 0.65, 0, 0.35, 1)
    }

    /// The visible (from, to) of a ring at loop position `u`, or nil when hidden.
    /// `start` = when it begins drawing, `full` = drawn, `hold` = erase begins.
    static func trim(at u: Double, start: Double, full: Double, hold: Double) -> (Double, Double)? {
        if u < start { return nil }
        if u < full { return (0, ease((u - start) / (full - start))) }
        if u < hold { return (0, 1) }
        return (ease((u - hold) / (1 - hold)), 1)
    }

    static func render(in context: inout GraphicsContext, size: CGFloat, phase: Double) {
        let stroke = JcLoaderGeometry.stroke(for: size)
        let rings: [(Path, (Double, Double)?)] = [
            (JcLoaderGeometry.ringA, trim(at: phase, start: 0, full: 0.42, hold: 0.60)),
            (JcLoaderGeometry.ringB, trim(at: phase, start: 0.12, full: 0.50, hold: 0.66)),
        ]
        for (ring, span) in rings {
            guard let (from, to) = span, to - from > 0.0005 else { continue }
            let path = JcLoaderGeometry.scaled(ring, to: size).trimmedPath(from: from, to: to)
            context.stroke(path, with: .foreground, style: stroke)
        }
    }
}
