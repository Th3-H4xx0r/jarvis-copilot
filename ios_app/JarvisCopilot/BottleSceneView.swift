import SwiftUI
import SceneKit

/// The procedural bottle rendered live in SceneKit.
///
/// This wraps `SCNView` directly rather than using SwiftUI's `SceneView`, because
/// `SceneView` gives no way to reach the underlying view's `backgroundColor` /
/// `isOpaque` — setting `scene.background.contents = .clear` still leaves it drawing
/// on an opaque white backing.
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

    var body: some View {
        Group {
            if let live {
                SceneKitView(live: live, spin: spin)
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

#if canImport(UIKit)
private struct SceneKitView: UIViewRepresentable {
    let live: BottleModel.Live
    let spin: Bool

    func makeUIView(context: Context) -> SCNView { configure(SCNView()) }
    func updateUIView(_ view: SCNView, context: Context) {
        // Changes over the view's lifetime, unlike the camera pose.
        view.rendersContinuously = spin
    }

    private func configure(_ view: SCNView) -> SCNView {
        view.scene = live.scene
        view.pointOfView = live.camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        // The pose is driven entirely by the animations — no manual orbiting.
        view.allowsCameraControl = false
        view.rendersContinuously = spin
        view.autoenablesDefaultLighting = false
        // Half rate: a slow turntable doesn't need 60fps, and these can be on screen
        // several at a time.
        view.preferredFramesPerSecond = 30
        return view
    }
}
#else
private struct SceneKitView: NSViewRepresentable {
    let live: BottleModel.Live
    let spin: Bool

    func makeNSView(context: Context) -> SCNView { configure(SCNView()) }
    func updateNSView(_ view: SCNView, context: Context) {
        view.rendersContinuously = spin
    }

    private func configure(_ view: SCNView) -> SCNView {
        view.scene = live.scene
        view.pointOfView = live.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        // The pose is driven entirely by the animations — no manual orbiting.
        view.allowsCameraControl = false
        view.rendersContinuously = spin
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 30
        return view
    }
}
#endif
