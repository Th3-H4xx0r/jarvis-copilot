import SceneKit
import SwiftUI
import UIKit

/// The lights in the car: the Camry cut away at the waist, each lamp of the layout drawn where it
/// is, glowing in what the lights were last set to — or grey while they aren't connected.
@MainActor
final class CarLightsScene {
    /// What every lamp shows (they all show the same thing).
    enum Look: Equatable {
        case off
        case solid(MelkColor, brightness: Int)
        /// An effect, scene or music: the colour isn't known, so it cycles.
        case cycling
        /// Not paired, or not connected: grey.
        case unavailable
    }

    let live: CarModel.Live
    private(set) var layout = CarLightLayout(version: 1, lamps: [])
    private var lamps: [String: (core: SCNNode, glow: SCNNode, center: SCNVector3)] = [:]
    private var look: Look?
    private(set) var selected: String?

    init(mesh: CarModel.Mesh? = CarModel.bundled) {
        live = CarModel.Live(presentation: .cutaway, spin: false, mesh: mesh)
    }

    /// Rebuild the lamps for a new or edited layout.
    func show(_ next: CarLightLayout) {
        guard next != layout else { return }
        layout = next
        lamps.values.forEach { $0.core.removeFromParentNode(); $0.glow.removeFromParentNode() }
        lamps = [:]
        for lamp in next.lamps {
            guard let shape = lamp.shape, let center = lamp.center else { continue }
            let (core, glow) = Self.nodes(for: shape)
            core.name = "lamp:\(lamp.id)"
            live.spinner.addChildNode(core)
            live.spinner.addChildNode(glow)
            lamps[lamp.id] = (core, glow, SCNVector3(center.x, center.y, center.z))
        }
        let current = look
        look = nil
        show(current ?? .unavailable)
        markSelection()
    }

    private static func material(alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.transparency = alpha
        return m
    }

    /// A thin bright core and a soft glow around it.
    private static func nodes(for shape: CarLightLayout.Lamp.Shape) -> (SCNNode, SCNNode) {
        switch shape {
        case .point(let p):
            let core = SCNNode(geometry: SCNSphere(radius: 0.035))
            let glow = SCNNode(geometry: SCNSphere(radius: 0.085))
            for node in [core, glow] { node.simdPosition = p }
            core.geometry?.firstMaterial = material(alpha: 1)
            glow.geometry?.firstMaterial = material(alpha: 0.35)
            core.renderingOrder = 30; glow.renderingOrder = 31
            return (core, glow)
        case .strip(let a, let b):
            let length = CGFloat(simd_length(b - a))
            let core = SCNNode(geometry: SCNCapsule(capRadius: 0.014, height: max(length, 0.05)))
            let glow = SCNNode(geometry: SCNCapsule(capRadius: 0.05, height: max(length, 0.1) + 0.06))
            let direction = length > 0.0001 ? simd_normalize(b - a) : SIMD3<Float>(0, 1, 0)
            for node in [core, glow] {
                node.simdPosition = (a + b) / 2
                // A capsule runs along Y: turn it onto the strip.
                node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)
            }
            core.geometry?.firstMaterial = material(alpha: 1)
            glow.geometry?.firstMaterial = material(alpha: 0.35)
            core.renderingOrder = 30; glow.renderingOrder = 31
            return (core, glow)
        }
    }

    func show(_ next: Look) {
        guard look != next else { return }
        look = next
        for nodes in lamps.values {
            nodes.core.removeAction(forKey: "cycle")
            nodes.glow.removeAction(forKey: "cycle")
            switch next {
            case .off:
                set(nodes, UIColor(white: 0.25, alpha: 1), glow: 0)
            case .unavailable:
                set(nodes, UIColor(white: 0.42, alpha: 1), glow: 0)
            case .solid(let c, let brightness):
                let level = 0.35 + 0.65 * CGFloat(max(0, min(100, brightness))) / 100
                set(nodes, UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1),
                    glow: 0.22 * level)
            case .cycling:
                let cycle = SCNAction.repeatForever(.customAction(duration: 4) { node, elapsed in
                    let color = UIColor(hue: elapsed / 4, saturation: 1, brightness: 1, alpha: 1)
                    node.geometry?.firstMaterial?.diffuse.contents = color
                    node.geometry?.firstMaterial?.emission.contents = color
                })
                nodes.glow.isHidden = false
                nodes.glow.geometry?.firstMaterial?.transparency = 0.2
                nodes.core.runAction(cycle, forKey: "cycle")
                nodes.glow.runAction(cycle, forKey: "cycle")
            }
        }
        markSelection()
    }

    private func set(_ nodes: (core: SCNNode, glow: SCNNode, center: SCNVector3), _ color: UIColor, glow: CGFloat) {
        for node in [nodes.core, nodes.glow] {
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.geometry?.firstMaterial?.emission.contents = color
        }
        nodes.glow.geometry?.firstMaterial?.transparency = glow
        nodes.glow.isHidden = glow == 0
    }

    // MARK: Editing

    /// The lamp being arranged: drawn larger, in white, pulsing.
    func select(_ id: String?) {
        guard id != selected else { return }
        selected = id
        // Repaint everything (a deselected lamp goes back to the lights' colour), then mark it.
        let current = look
        look = nil
        show(current ?? .unavailable)
    }

    private func markSelection() {
        for (id, nodes) in lamps {
            nodes.core.removeAction(forKey: "pulse")
            nodes.core.scale = SCNVector3(1, 1, 1)
            nodes.core.opacity = 1
            guard id == selected else { continue }
            // Thicker, not longer: a strip runs along its local Y.
            nodes.core.scale = SCNVector3(1.8, 1, 1.8)
            nodes.core.geometry?.firstMaterial?.diffuse.contents = UIColor.white
            nodes.core.geometry?.firstMaterial?.emission.contents = UIColor.white
            let pulse = SCNAction.sequence([.fadeOpacity(to: 0.35, duration: 0.5), .fadeOpacity(to: 1, duration: 0.5)])
            nodes.core.runAction(.repeatForever(pulse), forKey: "pulse")
        }
    }

    /// The lamp nearest a point on screen, if one is within reach.
    func lamp(near point: CGPoint, in view: SCNView, reach: CGFloat = 44) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (id, nodes) in lamps {
            let p = view.projectPoint(live.spinner.convertPosition(nodes.center, to: nil))
            let d = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
            if d <= reach, d < (best?.distance ?? .infinity) { best = (id, d) }
        }
        return best?.id
    }

    /// The point of the cabin under a finger, in car space — a little off the surface so the lamp
    /// sits on it rather than inside it. Nil off the cabin (or above the cut).
    func cabinPoint(at point: CGPoint, in view: SCNView) -> SIMD3<Float>? {
        let hits = view.hitTest(point, options: [
            .categoryBitMask: CarModel.cabinCategory,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
        ])
        for hit in hits {
            let local = live.spinner.convertPosition(hit.worldCoordinates, from: nil)
            let normal = live.spinner.convertVector(hit.worldNormal, from: nil)
            guard local.y <= CarModel.beltHeight else { continue }
            return SIMD3(Float(local.x), Float(local.y), Float(local.z)) + simd_normalize(SIMD3(Float(normal.x), Float(normal.y), Float(normal.z))) * 0.02
        }
        return nil
    }

    /// Where a lamp lands on screen (for tests).
    func screenPoint(of id: String, in renderer: SCNSceneRenderer) -> CGPoint? {
        guard let nodes = lamps[id] else { return nil }
        let p = renderer.projectPoint(live.spinner.convertPosition(nodes.center, to: nil))
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// What the lamps show for the lights' state — grey unless a controller is connected.
    static func look(manager: CarLightsManager) -> Look {
        guard let ready = manager.controllers.first(where: { manager.link(for: $0.id) == .ready }) else { return .unavailable }
        let s = manager.state(for: ready.id)
        if !s.on { return .off }
        if let c = s.displayColor { return .solid(c, brightness: s.shownBrightness) }
        return .cycling
    }
}

/// The preview as a view. Gestures are the editor's; elsewhere it's a picture.
struct CarLightsPreview: View {
    let layout: CarLightLayout
    let look: CarLightsScene.Look
    var selected: String? = nil
    var onTap: ((CGPoint, SCNView, CarLightsScene) -> Void)? = nil
    var onPan: ((UIPanGestureRecognizer, CarLightsScene) -> Void)? = nil

    @State private var scene: CarLightsScene?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let scene {
                SceneCanvas(scene: scene.live.scene, camera: scene.live.camera,
                            rendersContinuously: (look == .cycling || selected != nil) && scenePhase == .active,
                            onTap: onTap.map { tap in { point, view in tap(point, view, scene) } },
                            onPan: onPan.map { pan in { recognizer in pan(recognizer, scene) } })
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard scene == nil else { return }
            let made = CarLightsScene()
            made.show(layout)
            made.show(look)
            made.select(selected)
            scene = made
        }
        .onChange(of: layout) { _, next in scene?.show(next) }
        .onChange(of: look) { _, next in scene?.show(next) }
        .onChange(of: selected) { _, next in scene?.select(next) }
    }
}
