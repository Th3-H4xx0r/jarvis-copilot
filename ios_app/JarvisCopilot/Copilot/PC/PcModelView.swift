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
        [AnyHashable(lit), AnyHashable(state), AnyHashable(map?.rev ?? -1)]
    }

    var body: some View {
        SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animated,
                    onHorizontalPan: { pan in turn(pan) },
                    onTap: { point, view in tap(point, view) },
                    onRender: { [glow, live] _ in glow.tick(live) },
                    look: lookKey)
            .onAppear { refresh() }
            .onChange(of: lookKey) { refresh() }
            .accessibilityLabel("3D model of your PC")
    }

    private func refresh() {
        glow.set(state: state, map: map, lit: lit)
        glow.apply(live)    // now, for the first frame and for a still
    }

    private func turn(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: turnStart = live.root.eulerAngles.y
        case .changed: live.root.eulerAngles.y = turnStart + Float(pan.translation(in: pan.view).x / 140)
        default: break
        }
    }

    private func tap(_ point: CGPoint, _ view: SCNView) {
        // Every hit, closest first: the case's glass sits in front of everything and is looked through.
        let tap = PcModel.resolve(view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]), in: live)
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
