import SwiftUI
import SceneKit

/// The procedural bottle rendered live in SceneKit.
struct BottleSceneView: View {
    /// Slow turntable rotation. Costs a continuous render, so use it sparingly.
    var spin = false
    /// Scales and settles the bottle in when it first appears.
    var entrance = false
    /// Dollies in and pulses a UV glow.
    var sterilising = false
    /// A fixed lean, for the static card pose.
    var tilt: CGFloat = 0
    /// Slides the framing so the bottle can sit off-centre.
    var cameraX: Float = 0
    /// Slides the framing vertically; NaN keeps the default.
    var cameraY: Float = .nan
    /// Overrides the camera distance; 0 keeps the default.
    var cameraZ: Float = 0

    @State private var live: BottleModel.Live?
    /// Optional so previews and tests without the shell still render.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    /// Render the turntable only while the Devices tab is on screen: every tab
    /// stays mounted, so an ungated 30 fps render never stopped.
    private var spinning: Bool {
        spin && scenePhase == .active && (router.map { $0.selectedTab == .devices } ?? true)
    }

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: spinning)
            } else {
                Color.clear
            }
        }
        // Built on appear rather than in an initialiser: a card can be re-created many
        // times during layout and the scene only needs to exist once per view.
        .onAppear {
            if live == nil {
                let l = BottleModel.Live(spin: spin, tilt: tilt, cameraX: cameraX,
                                         cameraY: cameraY, cameraZ: cameraZ)
                if entrance { l.playEntrance() }
                if sterilising { l.setSterilising(true) }
                live = l
            }
        }
        .onChange(of: sterilising) { _, on in live?.setSterilising(on) }
    }
}
