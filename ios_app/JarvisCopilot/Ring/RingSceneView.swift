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
    /// Turn wherever it is shown (a workout's wearable sheet), not only on
    /// the Devices tab.
    var animatesAnywhere = false

    var body: some View {
        WearableSceneCanvas(spin: spin, entrance: entrance, pulsing: pulsing, flashToken: flashToken,
                            animatesAnywhere: animatesAnywhere) {
            RingModel.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds)
        }
    }
}

/// A wearable's stage drawn live: the turn, the entrance, the LEDs breathing through a measurement,
/// the find flash. The turn costs a continuous render, so it runs only on the visible Devices tab
/// unless `animatesAnywhere`.
struct WearableSceneCanvas<Stage: WearableStage>: View {
    var spin: Bool
    var entrance: Bool
    var pulsing: Bool
    var flashToken: Int
    /// Bump when a gesture lands (the X5's touch target lights up).
    var touchToken = 0
    var animatesAnywhere: Bool
    let make: () -> Stage

    @State private var live: Stage?
    /// Optional so previews and tests without the shell still render.
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
            let scene = make()
            if entrance { scene.playEntrance() }
            if pulsing { scene.setPulsing(true) }
            live = scene
        }
        .onChange(of: pulsing) { _, on in live?.setPulsing(on) }
        .onChange(of: flashToken) { _, _ in live?.flash() }
        .onChange(of: touchToken) { _, _ in live?.touch() }
    }
}
