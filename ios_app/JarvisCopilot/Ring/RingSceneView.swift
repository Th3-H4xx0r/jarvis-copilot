import SceneKit
import SwiftUI

/// The procedural ring rendered live in SceneKit.
struct RingSceneView: View {
    /// Slow turntable. Costs a continuous render, so it is gated to the visible Devices tab.
    var spin = true
    var entrance = false
    /// LEDs breathe while a measurement runs.
    var pulsing = false
    /// Bump to play the "find ring" flash.
    var flashToken = 0
    var tilt: Float = RingModel.defaultTilt
    var cameraDistance: Float = 4.2
    /// Seconds for one turn.
    var spinSeconds: Double = 34

    @State private var live: RingModel.Live?
    /// Optional so previews and tests without the shell still render.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        (spin || pulsing) && scenePhase == .active && (router.map { $0.selectedTab == .devices } ?? true)
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
            let scene = RingModel.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance,
                                       spinSeconds: spinSeconds)
            if entrance { scene.playEntrance() }
            if pulsing { scene.setPulsing(true) }
            live = scene
        }
        .onChange(of: pulsing) { _, on in live?.setPulsing(on) }
        .onChange(of: flashToken) { _, _ in live?.flash() }
    }
}
