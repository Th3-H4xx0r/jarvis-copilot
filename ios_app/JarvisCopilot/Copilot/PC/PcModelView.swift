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

    @State private var live = PcModel.build()
    @State private var glow = PcGlow()
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
        guard let node = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first?.node
        else { return }
        if let part = PcModel.part(of: node) { onTapPart?(part) }
        else if let comp = PcModel.component(of: node) { onTapComponent?(comp) }
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
