import SceneKit
import SwiftUI

/// The `SCNView` behind `SceneCanvas`: it draws only while its window's scene is on screen.
///
/// SceneKit redraws whenever an action runs, `rendersContinuously` or not — a band's pulse, the
/// flash on each reading — and the keepalive keeps the process alive in a pocket, so a model left
/// open kept drawing all night (Oct 17: ~35 CPU-s an hour on SceneKit's thread with the phone
/// asleep). Off screen — app in the background, or another tab — its scene is paused; the frame
/// it last drew stays, so the app switcher still shows it.
final class SceneCanvasView: SCNView {
    /// What the model asks for: every frame while it animates. Granted only on screen.
    var wantsContinuous = false {
        didSet { if wantsContinuous != oldValue { showOrPause() } }
    }

    override var scene: SCNScene? {
        didSet { showOrPause() }
    }

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        for name in [UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("SceneCanvasView is made in code") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        showOrPause()
    }

    /// Whichever scene changed, ours is read from the window: the others' are a no-op.
    @objc private func sceneChanged(_ note: Notification) { showOrPause() }

    /// In a window whose scene is in the foreground (Control Center pulled down still counts).
    var isShowing: Bool {
        guard let state = window?.windowScene?.activationState else { return false }
        return state == .foregroundActive || state == .foregroundInactive
    }

    private func showOrPause() {
        let showing = isShowing
        rendersContinuously = wantsContinuous && showing
        if let scene, scene.isPaused == showing { scene.isPaused = !showing }
    }
}

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
    /// A tap on the scene, with the view to hit-test or project against.
    var onTap: ((CGPoint, SCNView) -> Void)? = nil
    /// A drag in any direction (the lamp editor; nothing scrolls under it).
    var onPan: ((UIPanGestureRecognizer) -> Void)? = nil
    /// Called every frame on SceneKit's render thread, before it draws — for an entrance driven by
    /// the frames actually being drawn. Taken once, when the view is made.
    var onRender: ((TimeInterval) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SceneCanvasView(frame: .zero, options: nil)
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        // The pose is driven entirely by the animations — no manual orbiting.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = preferredFramesPerSecond
        view.wantsContinuous = rendersContinuously
        context.coordinator.onPan = onHorizontalPan
        context.coordinator.onTap = onTap
        context.coordinator.onFreePan = onPan
        if let onRender {
            context.coordinator.onRender = onRender
            view.delegate = context.coordinator
        }
        if onPan != nil {
            view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.freePanned(_:))))
        }
        if onTap != nil {
            view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        }
        if onHorizontalPan != nil {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
            pan.delegate = context.coordinator
            view.addGestureRecognizer(pan)
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== scene {
            view.scene = scene
            view.pointOfView = camera
        }
        (view as? SceneCanvasView)?.wantsContinuous = rendersContinuously
        context.coordinator.onPan = onHorizontalPan
        context.coordinator.onTap = onTap
        context.coordinator.onFreePan = onPan
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        var onPan: ((UIPanGestureRecognizer) -> Void)?
        var onTap: ((CGPoint, SCNView) -> Void)?
        var onFreePan: ((UIPanGestureRecognizer) -> Void)?
        /// Set once when the view is made; called on SceneKit's render thread.
        var onRender: ((TimeInterval) -> Void)?

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            onRender?(time)
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) { onPan?(pan) }
        @objc func freePanned(_ pan: UIPanGestureRecognizer) { onFreePan?(pan) }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view as? SCNView else { return }
            onTap?(tap.location(in: view), view)
        }

        /// Only a mostly-sideways drag turns the model; anything else scrolls the page.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
