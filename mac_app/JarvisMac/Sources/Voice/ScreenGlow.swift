import AppKit
import Observation
import SwiftUI

/// The screen's edge as two halves, each from the top centre to the bottom
/// centre — one by the right side, one by the left. The push-to-talk glow
/// draws itself along them: out of the notch, down both sides, meeting at the
/// bottom; and back up when it goes.
enum EdgeGlowPath {
    static func half(in rect: CGRect, corner: CGFloat, right: Bool) -> Path {
        let r = min(corner, rect.width / 2, rect.height / 2)
        let midX = rect.midX
        var p = Path()
        p.move(to: CGPoint(x: midX, y: rect.minY))
        if right {
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        }
        p.addLine(to: CGPoint(x: midX, y: rect.maxY))
        return p
    }
}

/// What the glow window draws: how far along the edge it has come (0 = not
/// at all, 1 = the two halves met at the bottom), and its fade.
@MainActor
@Observable
final class ScreenGlowModel {
    var progress: CGFloat = 0
    var opacity: Double = 1
    var visible = false
}

/// The Siri-like light around the screen while you hold to talk: Jarvis's
/// colours, slowly turning, soft outside and bright at the edge.
struct ScreenGlowView: View {
    let model: ScreenGlowModel
    static let colors: [Color] = [
        Color(red: 0.25, green: 0.66, blue: 1.0),   // blue
        Color(red: 0.55, green: 0.38, blue: 1.0),   // violet
        Color(red: 1.0, green: 0.35, blue: 0.80),   // pink
        Color(red: 1.0, green: 0.62, blue: 0.30),   // amber
        Color(red: 0.25, green: 0.66, blue: 1.0),
    ]

    var body: some View {
        GeometryReader { g in
            let rect = CGRect(origin: .zero, size: g.size)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.visible)) { ctx in
                let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360
                let gradient = AngularGradient(colors: Self.colors, center: .center, angle: .degrees(turn))
                ZStack {
                    GlowHalves(rect: rect, progress: model.progress)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 34, lineCap: .round))
                        .blur(radius: 26).opacity(0.7)
                    GlowHalves(rect: rect, progress: model.progress)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .blur(radius: 6).opacity(0.85)
                    GlowHalves(rect: rect, progress: model.progress)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .opacity(0.95)
                }
                .drawingGroup()
            }
        }
        .opacity(model.opacity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Both halves of the edge, trimmed to how far the glow has come. A Shape so
/// `progress` animates.
struct GlowHalves: Shape {
    let rect: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        let corner: CGFloat = 12
        var p = Path()
        p.addPath(EdgeGlowPath.half(in: rect, corner: corner, right: true).trimmedPath(from: 0, to: progress))
        p.addPath(EdgeGlowPath.half(in: rect, corner: corner, right: false).trimmedPath(from: 0, to: progress))
        return p
    }
}

/// The glow's window: borderless, click-through, over everything but the
/// island, on every Space and over full-screen apps. Built once; only drawn
/// while it shows (Settings → Voice → Glow around the screen).
@MainActor
final class ScreenGlow {
    static let shared = ScreenGlow()

    private let model = ScreenGlowModel()
    private var window: NSPanel?
    private var hideTask: Task<Void, Never>?

    var isShowing: Bool { model.visible }

    /// Build the window ahead of the first use (so showing it costs nothing).
    func prepare() {
        _ = panel()
    }

    func show(on screen: NSScreen?) {
        guard Prefs.edgeGlow, let screen = screen ?? NSScreen.main else { return }
        hideTask?.cancel()
        let w = panel()
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        model.visible = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.progress = 1
            model.opacity = 0
            withAnimation(.easeOut(duration: 0.3)) { model.opacity = 1 }
        } else {
            model.opacity = 1
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.8)) { model.progress = 1 }
        }
    }

    /// Back up to the top, then gone.
    func hide() {
        guard model.visible else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce {
            withAnimation(.easeIn(duration: 0.25)) { model.opacity = 0 }
        } else {
            withAnimation(.timingCurve(0.55, 0, 0.75, 0.5, duration: 0.55)) { model.progress = 0 }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(reduce ? 0.3 : 0.6))
            guard let self, !Task.isCancelled else { return }
            self.model.visible = false
            self.window?.orderOut(nil)
        }
    }

    private func panel() -> NSPanel {
        if let window { return window }
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        // Under the island (main menu + 3), over everything else.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: ScreenGlowView(model: model))
        window = w
        return w
    }
}
