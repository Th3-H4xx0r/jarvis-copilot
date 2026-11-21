import SceneKit
import SwiftUI

/// The PC's 3D model, glowing LED by LED with what the PC's lights show: it runs the same effect maths
/// as the PC (PcEffects) on its own clock, so nothing is streamed. Drag sideways to turn it; tap a part.
/// Where `sceneStills` is set (the Wearables card) it draws one still frame in the current colours.
struct PcModelView: View {
    let state: PcLightingState?
    let map: PcLedMap?
    /// False: drawn unlit (PC Lighting off, the PC asleep, or not set up).
    var lit: Bool = true
    var onTapPart: ((PcPart) -> Void)? = nil
    var onTapComponent: ((String) -> Void)? = nil
    /// Calibration: the exact LED socket tapped (a fan's sector, a strip or logo segment).
    var onTapLED: ((PcLedKey) -> Void)? = nil
    /// Every tap, resolved (for highlighting what was tapped).
    var onTapTarget: ((PcModel.Tap) -> Void)? = nil
    /// Node names outlined in white (fan.bottom.1, part.strip, comp.gpu …).
    var highlighted: [String] = []
    /// Drawing a strip: a drag on the model draws a line; called with its ends when the finger lifts.
    var drawing = false
    var onDraw: ((SCNVector3, SCNVector3) -> Void)? = nil
    /// Bright, even light for finding parts.
    var workLight = false
    /// Free camera (full screen): drag to turn, pinch to zoom, two fingers to move.
    var camera: SceneCameraControl.Mode = .off
    /// A camera view, applied whenever `poseToken` changes.
    var pose: PcModel.Pose = .hero
    var poseToken = 0
    @State private var drawStart: SCNVector3?
    @State private var drawEnd: SCNVector3?

    /// Built the first time it's drawn, then kept: a SwiftUI @State initial value is evaluated on every
    /// view init, and a scene build per parent refresh was jank and battery.
    @State private var holder = PcLiveHolder()
    @State private var glow = PcGlow()
    private var live: PcModel.Live { holder.live }
    @State private var turnStart: Float = 0

    private var animated: Bool {
        guard lit, let state, state.on, state.frozenAt == nil else { return false }
        return PcPart.allCases.contains { PcEffect(rawValue: state.light($0).effect)?.animated ?? false }
    }

    private var lookKey: AnyHashable {
        [AnyHashable(lit), AnyHashable(state), AnyHashable(map), AnyHashable(highlighted), AnyHashable(workLight)]
    }

    var body: some View {
        SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animated,
                    onHorizontalPan: onDraw == nil && camera == .off ? { pan in turn(pan) } : nil,
                    onTap: { point, view in tap(point, view) },
                    onPan: onDraw == nil ? nil : { pan in draw(pan) },
                    onRender: { [glow, live] _ in glow.tick(live) },
                    look: lookKey,
                    cameraControl: camera, cameraTarget: PcModel.target, cameraReset: poseToken)
            .onAppear { if pose != .hero { PcModel.aim(live.camera, pose) }; refresh() }
            .onChange(of: poseToken) { PcModel.aim(live.camera, pose) }
            .onChange(of: lookKey) { refresh() }
            .accessibilityLabel("3D model of your PC")
    }

    private func refresh() {
        glow.set(state: state, map: map, lit: lit)
        glow.apply(live)    // now, for the first frame and for a still
        PcModel.highlight(highlighted, in: live)
        PcModel.workLight(workLight, in: live)
    }

    private func turn(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: turnStart = live.root.eulerAngles.y
        case .changed: live.root.eulerAngles.y = turnStart + Float(pan.translation(in: pan.view).x / 140)
        default: break
        }
    }

    /// Drawing mode: the drag draws a line on the surface; otherwise it turns the model.
    private func draw(_ pan: UIPanGestureRecognizer) {
        guard drawing, let view = pan.view as? SCNView else { if camera == .off { turn(pan) }; return }
        let hits = view.hitTest(pan.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let p = PcModel.surfacePoint(hits, in: live)
        switch pan.state {
        case .began: drawStart = p; drawEnd = p
        case .changed: if p != nil { drawEnd = p }; PcModel.showDraft(from: drawStart, to: drawEnd, in: live)
        case .ended:
            if let a = drawStart, let b = drawEnd, simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)) > 0.1 { onDraw?(a, b) }
            fallthrough
        default: drawStart = nil; drawEnd = nil; PcModel.showDraft(from: nil, to: nil, in: live)
        }
    }

    private func tap(_ point: CGPoint, _ view: SCNView) {
        // Every hit, closest first: the case's glass sits in front of everything and is looked through.
        let tap = PcModel.resolve(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]), in: live)
        onTapTarget?(tap)
        if let onTapLED, let key = tap.key { onTapLED(key); return }
        if let part = tap.part { onTapPart?(part) }
        else if let comp = tap.component, comp != "case" || onTapPart == nil { onTapComponent?(comp) }
    }
}

final class PcLiveHolder {
    private var built: PcModel.Live?
    var live: PcModel.Live {
        if let built { return built }
        let made = PcModel.build()
        built = made
        return made
    }
}

/// What the model should show, shared with SceneKit's render thread.
final class PcGlow: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PcLightingState?
    private var map: PcLedMap?
    private var lit = true

    func set(state: PcLightingState?, map: PcLedMap?, lit: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.state = state; self.map = map; self.lit = lit
    }

    /// Every frame while something animates (render thread).
    func tick(_ live: PcModel.Live) { apply(live) }

    func apply(_ live: PcModel.Live, now: Date = Date()) {
        lock.lock()
        let state = self.state, map = self.map, lit = self.lit
        lock.unlock()
        guard lit, let state, let map, map.isMapped else { PcModel.unlit(live); return }
        PcModel.apply(colours: PcEffects.ledColours(state: state, map: map, now: now), map: map, to: live)
    }
}
