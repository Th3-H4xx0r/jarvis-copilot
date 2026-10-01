import SceneKit
import SwiftUI

/// The X5 in 3D, as `RingSceneView` shows the R12.
struct X5SceneView: View {
    /// Slow turntable. Costs a continuous render, so it is gated to the visible Devices tab.
    var spin = true
    var entrance = false
    /// The LEDs breathe while a measurement runs.
    var pulsing = false
    /// Bump to play the "find ring" flash.
    var flashToken = 0
    /// Bump when a gesture lands: the touch target lights up.
    var touchToken = 0
    var tilt: Float = X5Model.defaultTilt
    var cameraDistance: Float = 4.2
    var spinSeconds: Double = 34
    var animatesAnywhere = false

    @State private var live: X5Model.Live?
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        (spin || pulsing) && scenePhase == .active
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
            let scene = X5Model.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds)
            if entrance { scene.playEntrance() }
            if pulsing { scene.setPulsing(true) }
            live = scene
        }
        .onChange(of: pulsing) { _, on in live?.setPulsing(on) }
        .onChange(of: flashToken) { _, _ in live?.flash() }
        .onChange(of: touchToken) { _, _ in live?.touch() }
    }
}
