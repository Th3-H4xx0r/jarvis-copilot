import SceneKit
import SwiftUI
import UIKit

/// The lights in the car: the Camry cut away at the waist, each lamp from `CarLights.json` drawn
/// where it is, glowing in what its controller was last set to.
@MainActor
final class CarLightsScene {
    /// What one lamp shows.
    enum Look: Equatable {
        case off
        case solid(MelkColor, brightness: Int)
        /// An effect, scene or music: the colour isn't known, so it cycles.
        case cycling
        /// No controller paired yet: where it will be, dimly.
        case unpaired
    }

    let live: CarModel.Live
    let layout: CarLightLayout
    private var lamps: [String: (core: SCNNode, glow: SCNNode, center: SCNVector3)] = [:]
    private var looks: [String: Look] = [:]

    init(layout: CarLightLayout = .bundled, mesh: CarModel.Mesh? = CarModel.bundled) {
        self.layout = layout
        live = CarModel.Live(presentation: .cutaway, spin: false, mesh: mesh)
        for lamp in layout.lamps {
            guard let shape = lamp.shape, let center = lamp.center else { continue }
            let (core, glow) = Self.nodes(for: shape)
            core.name = "lamp:\(lamp.id)"
            live.spinner.addChildNode(core)
            live.spinner.addChildNode(glow)
            lamps[lamp.id] = (core, glow, SCNVector3(center.x, center.y, center.z))
        }
    }

    private static func material(alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.transparency = alpha
        return m
    }

    /// A thin bright core and a wide soft glow around it.
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
            for node in [core, glow] {
                node.simdPosition = (a + b) / 2
                // A capsule runs along Y: turn it onto the strip.
                node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(b - a))
            }
            core.geometry?.firstMaterial = material(alpha: 1)
            glow.geometry?.firstMaterial = material(alpha: 0.35)
            core.renderingOrder = 30; glow.renderingOrder = 31
            return (core, glow)
        }
    }

    func show(_ next: [String: Look]) {
        for (id, nodes) in lamps {
            let look = next[id] ?? .unpaired
            guard looks[id] != look else { continue }
            looks[id] = look
            nodes.core.removeAction(forKey: "cycle")
            nodes.glow.removeAction(forKey: "cycle")
            switch look {
            case .off:
                set(nodes, UIColor(white: 0.25, alpha: 1), glow: 0)
            case .unpaired:
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
    }

    private func set(_ nodes: (core: SCNNode, glow: SCNNode, center: SCNVector3), _ color: UIColor, glow: CGFloat) {
        for node in [nodes.core, nodes.glow] {
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.geometry?.firstMaterial?.emission.contents = color
        }
        nodes.glow.geometry?.firstMaterial?.transparency = glow
        nodes.glow.isHidden = glow == 0
    }

    var isAnimating: Bool { looks.values.contains(.cycling) }

    /// The lamp nearest a tap, if it's within reach of one.
    func lamp(near point: CGPoint, in view: SCNView, reach: CGFloat = 44) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (id, nodes) in lamps {
            let world = live.spinner.convertPosition(nodes.center, to: nil)
            let p = view.projectPoint(world)
            let d = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
            if d <= reach, d < (best?.distance ?? .infinity) { best = (id, d) }
        }
        return best?.id
    }

    /// Where a lamp lands on screen (for tests and labels).
    func screenPoint(of id: String, in renderer: SCNSceneRenderer) -> CGPoint? {
        guard let nodes = lamps[id] else { return nil }
        let p = renderer.projectPoint(live.spinner.convertPosition(nodes.center, to: nil))
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// Each lamp's look from the controllers' states.
    static func looks(layout: CarLightLayout, manager: CarLightsManager) -> [String: Look] {
        var out: [String: Look] = [:]
        for lamp in layout.lamps {
            guard let id = CarLightLayout.controllerID(for: lamp, in: manager.controllers) else {
                out[lamp.id] = .unpaired
                continue
            }
            let s = manager.state(for: id)
            if !s.on { out[lamp.id] = .off }
            else if let c = s.displayColor { out[lamp.id] = .solid(c, brightness: s.shownBrightness) }
            else { out[lamp.id] = .cycling }
        }
        return out
    }
}

/// The preview as a view: tap a lamp to pick it.
struct CarLightsPreview: View {
    let looks: [String: CarLightsScene.Look]
    var onTapLamp: ((String) -> Void)?

    @State private var scene: CarLightsScene?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let scene {
                SceneCanvas(scene: scene.live.scene, camera: scene.live.camera,
                            rendersContinuously: looks.values.contains(.cycling) && scenePhase == .active,
                            onTap: tapHandler(scene))
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard scene == nil else { return }
            let made = CarLightsScene()
            made.show(looks)
            scene = made
        }
        .onChange(of: looks) { _, next in scene?.show(next) }
    }

    private func tapHandler(_ scene: CarLightsScene) -> ((CGPoint, SCNView) -> Void)? {
        guard let onTapLamp else { return nil }
        return { point, view in
            if let id = scene.lamp(near: point, in: view) { onTapLamp(id) }
        }
    }
}
