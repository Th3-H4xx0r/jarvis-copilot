import SceneKit
import SwiftUI

/// The HBand in 3D, as `X5SceneView` shows the X5.
struct BandSceneView: View {
    /// Slow turntable. Costs a continuous render, so it is gated to the visible Devices tab.
    var spin = true
    var entrance = false
    /// The LEDs breathe while a measurement runs.
    var pulsing = false
    /// Bump to play the "find band" flash.
    var flashToken = 0
    var tilt: Float = BandModel.defaultTilt
    var cameraDistance: Float = 4.6
    var spinSeconds: Double = 34
    var animatesAnywhere = false

    var body: some View {
        WearableSceneCanvas(spin: spin, entrance: entrance, pulsing: pulsing, flashToken: flashToken,
                            animatesAnywhere: animatesAnywhere) {
            BandModel.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds)
        }
    }
}
