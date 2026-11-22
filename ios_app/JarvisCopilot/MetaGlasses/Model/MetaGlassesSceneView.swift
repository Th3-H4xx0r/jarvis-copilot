import SceneKit
import SwiftUI

/// The Ray-Ban Meta Scriber Optics (Gen 2) 3D model (MetaGlassesModel) as a SwiftUI view: the
/// Wearables card and the glasses page hero.
struct MetaGlassesSceneView: View {
    /// Slow turntable; false holds the three-quarter pose. Costs a continuous render, so it only
    /// turns on the visible Devices tab.
    var spin: Bool = true
    /// The capture LED glows white and breathes, as while recording.
    var ledOn: Bool = false
    /// The temples folded in behind the front.
    var folded: Bool = false
    /// The part the simulator is exercising: the camera glides to it and marks it with a pulse
    /// (blue while listening or speaking, white for the camera, LED and touches). Nil returns to
    /// the turntable.
    var focus: MetaGlassesFocus? = nil

    @State private var live: MetaGlassesModel.Live?
    /// Optional so previews and tests without the shell still render.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sceneStills) private var stills

    /// Every frame only while something moves: the turntable, or a focus glide and its pulse.
    private var animating: Bool {
        scenePhase == .active && (spin || focus != nil)
            && (router.map { $0.selectedTab == .devices } ?? true)
    }

    /// What a still shows: drawn again when any of it changes.
    private struct Look: Hashable {
        var ledOn: Bool
        var folded: Bool
        var wide: Bool
        var part: MetaGlassesPart?
        var pulse: MetaGlassesPulse?
    }

    /// The card is square; a page hero is much wider than tall, so its camera comes in closer.
    private static func isWide(_ size: CGSize) -> Bool { size.width > size.height * 1.3 }
    private static func distance(wide: Bool) -> Float {
        wide ? MetaGlassesModel.heroDistance : MetaGlassesModel.cardDistance
    }

    var body: some View {
        GeometryReader { geo in
            let wide = Self.isWide(geo.size)
            Group {
                if let live {
                    SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating,
                                look: Look(ledOn: ledOn, folded: folded, wide: wide, part: focus?.part, pulse: focus?.pulse))
                } else {
                    Color.clear
                }
            }
            .onAppear {
                guard live == nil else { return }
                let scene = MetaGlassesModel.Live(spin: spin && !stills, cameraDistance: Self.distance(wide: wide),
                                                  folded: folded)
                if ledOn { scene.setLED(true, animated: !stills) }
                if let focus { scene.setFocus(focus, animated: false) }
                live = scene
            }
            .onChange(of: wide) { _, wide in live?.setIdleDistance(Self.distance(wide: wide)) }
        }
        .onChange(of: ledOn) { _, on in live?.setLED(on, animated: !stills) }
        .onChange(of: folded) { _, folded in live?.setFolded(folded, animated: !stills) }
        .onChange(of: spin) { _, spin in live?.setSpinning(spin && !stills) }
        .onChange(of: focus) { _, focus in live?.setFocus(focus, animated: !stills) }
    }
}
