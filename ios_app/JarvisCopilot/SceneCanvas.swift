import SceneKit
import SwiftUI

/// A transparent `SCNView` for the wearable models.
///
/// SwiftUI's `SceneView` gives no way to reach the view's `backgroundColor` /
/// `isOpaque`, so a `.clear` scene background still drew on an opaque white backing.
struct SceneCanvas: UIViewRepresentable {
    let scene: SCNScene
    let camera: SCNNode
    /// A continuous render costs power: only while something is animating.
    let rendersContinuously: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        // The pose is driven entirely by the animations — no manual orbiting.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        // Half rate: the animations are slow, and several models can be on screen.
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = rendersContinuously
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.rendersContinuously = rendersContinuously
    }
}
