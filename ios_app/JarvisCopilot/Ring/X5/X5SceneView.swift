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

    var body: some View {
        WearableSceneCanvas(spin: spin, entrance: entrance, pulsing: pulsing, flashToken: flashToken,
                            touchToken: touchToken, animatesAnywhere: animatesAnywhere) {
            X5Model.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds)
        }
    }
}
