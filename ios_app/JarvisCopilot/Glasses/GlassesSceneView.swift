import SceneKit
import SwiftUI

/// The procedural INMO GO3 rendered live in SceneKit.
struct GlassesSceneView: View {
    /// Slow turntable. Costs a continuous render, so it is gated to the visible Devices tab.
    var spin = true
    var entrance = false
    /// The green display glows while the glasses are connected.
    var lit = false
    var tilt: Float = InmoGo3Model.defaultTilt
    var cameraDistance: Float = 4.2
    /// Seconds for one turn.
    var spinSeconds: Double = 40
    /// Turn wherever it is shown, not only on the Devices tab.
    var animatesAnywhere = false

    @State private var live: InmoGo3Model.Live?
    /// Optional so previews and tests without the shell still render.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        spin && scenePhase == .active
            && (animatesAnywhere || (router.map { $0.selectedTab == .devices } ?? true))
    }

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard live == nil else { return }
            let scene = InmoGo3Model.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance,
                                          spinSeconds: spinSeconds)
            if entrance { scene.playEntrance() }
            if lit { scene.setLit(true) }
            live = scene
        }
        .onChange(of: lit) { _, on in live?.setLit(on) }
    }
}
