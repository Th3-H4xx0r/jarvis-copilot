import SwiftUI
import UIKit

/// Pinch-to-zoom on the shared computer screen (Mac or PC). The picture is drawn at
/// `offset + scale * p` for a point `p` of the unzoomed frame; taps are mapped back with `base(_:)`
/// so a click lands where his finger is at any zoom. The picture always covers the frame (no
/// panning past its edges).
struct MacScreenZoom: Equatable {
    static let maxScale: CGFloat = 5

    var scale: CGFloat = 1
    var offset: CGPoint = .zero

    var isZoomed: Bool { scale > 1.001 }

    /// A point in the visible (zoomed) frame → the same spot in the unzoomed frame.
    func base(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    /// Pinch by `factor` around `center`: the spot under his fingers stays under them.
    mutating func pinch(by factor: CGFloat, at center: CGPoint, in size: CGSize) {
        let anchor = base(center)
        scale = min(max(scale * factor, 1), Self.maxScale)
        offset = CGPoint(x: center.x - scale * anchor.x, y: center.y - scale * anchor.y)
        clamp(in: size)
    }

    /// Two-finger pan.
    mutating func pan(by delta: CGSize, in size: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
        clamp(in: size)
    }

    mutating func clamp(in size: CGSize) {
        if !isZoomed { scale = 1; offset = .zero; return }
        offset.x = min(0, max(size.width - scale * size.width, offset.x))
        offset.y = min(0, max(size.height - scale * size.height, offset.y))
    }
}

/// All touch input on the shared screen, in one UIKit view so pinch, two-finger pan, taps and
/// one-finger drags never fight: one finger is the mouse (tap = click, double tap = double-click,
/// drag = drag with the button held), two fingers zoom and pan the picture.
struct MacScreenTouchLayer: UIViewRepresentable {
    var onTap: (CGPoint, Int) -> Void
    var onDrag: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void   // state, start, current
    var onPinch: (CGFloat, CGPoint) -> Void                            // factor since last, centre
    var onPan: (CGSize) -> Void                                        // two-finger delta since last

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let c = context.coordinator

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: double)

        let drag = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.drag(_:)))
        drag.maximumNumberOfTouches = 1

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pinch.delegate = c
        pan.delegate = c

        c.mouseDrag = drag
        for g in [double, single, drag, pinch, pan] { view.addGestureRecognizer(g) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MacScreenTouchLayer
        private var dragStart: CGPoint = .zero
        weak var mouseDrag: UIPanGestureRecognizer?

        init(_ parent: MacScreenTouchLayer) { self.parent = parent }

        @objc func singleTap(_ g: UITapGestureRecognizer) { parent.onTap(g.location(in: g.view), 1) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { parent.onTap(g.location(in: g.view), 2) }

        @objc func drag(_ g: UIPanGestureRecognizer) {
            let now = g.location(in: g.view)
            if g.state == .began {
                let t = g.translation(in: g.view)
                dragStart = CGPoint(x: now.x - t.x, y: now.y - t.y)
            }
            parent.onDrag(g.state, dragStart, now)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began, let d = mouseDrag, d.state == .began || d.state == .changed {
                // A second finger landed mid-drag: cancel the mouse drag (it releases) and zoom.
                d.isEnabled = false
                d.isEnabled = true
            }
            guard g.state == .began || g.state == .changed, g.numberOfTouches >= 2 else { return }
            parent.onPinch(g.scale, g.location(in: g.view))
            g.scale = 1
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard g.state == .began || g.state == .changed else { return }
            let t = g.translation(in: g.view)
            parent.onPan(CGSize(width: t.x, height: t.y))
            g.setTranslation(.zero, in: g.view)
        }

        // Pinch and the two-finger pan run together (zoom while moving); the one-finger mouse
        // drag never runs alongside them.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            Self.isTwoFinger(g) && Self.isTwoFinger(other)
        }

        private static func isTwoFinger(_ g: UIGestureRecognizer) -> Bool {
            g is UIPinchGestureRecognizer || ((g as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 1) >= 2
        }
    }
}
