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
    /// Half rate by default: the models turn slowly, and several can be on screen.
    var preferredFramesPerSecond = 30
    /// A sideways drag on the model (turntable). Vertical drags are left to the scroll view around it.
    var onHorizontalPan: ((UIPanGestureRecognizer) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        view.preferredFramesPerSecond = preferredFramesPerSecond
        view.rendersContinuously = rendersContinuously
        context.coordinator.onPan = onHorizontalPan
        if onHorizontalPan != nil {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
            pan.delegate = context.coordinator
            view.addGestureRecognizer(pan)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.rendersContinuously = rendersContinuously
        context.coordinator.onPan = onHorizontalPan
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPan: ((UIPanGestureRecognizer) -> Void)?

        @objc func panned(_ pan: UIPanGestureRecognizer) { onPan?(pan) }

        /// Only a mostly-sideways drag turns the model; anything else scrolls the page.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
