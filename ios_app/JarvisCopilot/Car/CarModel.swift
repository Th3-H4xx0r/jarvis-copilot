import SceneKit
import SwiftUI
import UIKit

/// The car on the Car card and page: the baked Camry (`Camry.bin`, made by
/// `scripts/car/bake_car.py` from Ddiaz Design's model — CC BY-NC-SA 4.0, `Camry-LICENSE.md`).
/// The bake keeps one mesh per kind of part (paint, glass, chrome, …) and drops the textures,
/// so each part gets its own material here: that is how the paint is Dark Cosmos and how the
/// lamps glow while the phone is in the car.
///
/// Car space: metres, the wheels on y = 0, centred, the front toward +Z.
enum CarModel {
    /// Same order as `SLOTS` in the bake script.
    enum Slot: UInt32, CaseIterable {
        case paint, glass, chrome, glossTrim, matteTrim, rubber, wheel, lampLens
        case lampInner, lampGlow, tailLens, amberLens, interior, brake, mirror
    }

    struct Mesh {
        let parts: [(slot: Slot, geometry: SCNGeometry)]
        let min: SIMD3<Float>
        let max: SIMD3<Float>
    }

    /// Reads `Camry.bin`: "JCCR", version, slot count, bounds, then per slot its id, vertex and
    /// index counts, positions, normals and 32-bit indices. Nil for anything malformed.
    static func mesh(from input: Data) -> Mesh? {
        let data = Data(input)   // a slice keeps its parent's indices; `subdata(in:)` below assumes 0
        guard data.count >= 36, data.prefix(4) == Data("JCCR".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }.littleEndian)
        }
        func f32(_ at: Int) -> Float { Float(bitPattern: UInt32(u32(at))) }
        guard u32(4) == 1 else { return nil }
        let slots = u32(8)
        let lo = SIMD3(f32(12), f32(16), f32(20)), hi = SIMD3(f32(24), f32(28), f32(32))
        var at = 36
        var parts: [(Slot, SCNGeometry)] = []
        for _ in 0..<slots {
            guard at + 12 <= data.count, let slot = Slot(rawValue: UInt32(u32(at))) else { return nil }
            let vertices = u32(at + 4), indices = u32(at + 8)
            let positionsAt = at + 12, normalsAt = positionsAt + vertices * 12, indicesAt = normalsAt + vertices * 12
            let end = indicesAt + indices * 4
            guard vertices > 0, indices % 3 == 0, end <= data.count else { return nil }
            // An index past the vertices would have Metal read beyond the buffer.
            let inRange = data.withUnsafeBytes { raw in
                (0..<indices).allSatisfy { i in
                    Int(raw.loadUnaligned(fromByteOffset: indicesAt + i * 4, as: UInt32.self).littleEndian) < vertices
                }
            }
            guard inRange else { return nil }
            let source = { (semantic: SCNGeometrySource.Semantic, offset: Int) in
                SCNGeometrySource(data: data.subdata(in: offset..<(offset + vertices * 12)), semantic: semantic,
                                  vectorCount: vertices, usesFloatComponents: true, componentsPerVector: 3,
                                  bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            }
            let element = SCNGeometryElement(data: data.subdata(in: indicesAt..<end), primitiveType: .triangles,
                                             primitiveCount: indices / 3, bytesPerIndex: 4)
            parts.append((slot, SCNGeometry(sources: [source(.vertex, positionsAt), source(.normal, normalsAt)],
                                             elements: [element])))
            at = end
        }
        return parts.isEmpty ? nil : Mesh(parts: parts, min: lo, max: hi)
    }

    /// The car shipped with the app; nil leaves the card without a model.
    static let bundled: Mesh? = Bundle.main.url(forResource: "Camry", withExtension: "bin")
        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        .flatMap(mesh(from:))

    // MARK: Materials

    /// Dark Cosmos — Toyota 8Z3, new for 2026: a deep, hazy slate blue with a violet cast, matched
    /// against Toyota's own picture of the SE.
    /// Darker than the photo's raw pixels on purpose: the app shows it on black, where the same
    /// paint reads much lighter than on Toyota's white page.
    static let darkCosmos = UIColor(red: 0.10, green: 0.112, blue: 0.185, alpha: 1)

    private static func pbr(_ color: UIColor, roughness: CGFloat, metalness: CGFloat = 0,
                            clearCoat: CGFloat = 0, opacity: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = 0.04
        if opacity < 1 {
            m.transparency = opacity
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
        }
        return m
    }

    static func material(for slot: Slot) -> SCNMaterial {
        switch slot {
        case .paint: return pbr(darkCosmos, roughness: 0.38, metalness: 0.45, clearCoat: 0.8)
        case .glass: return pbr(UIColor(white: 0.01, alpha: 1), roughness: 0.04, clearCoat: 1, opacity: 0.78)
        // The SE's trim is blacked out — window surround, sill strip, badges, wheel faces.
        case .chrome: return pbr(UIColor(white: 0.08, alpha: 1), roughness: 0.18, metalness: 1)
        case .glossTrim: return pbr(UIColor(white: 0.02, alpha: 1), roughness: 0.14, clearCoat: 0.6)
        case .matteTrim: return pbr(UIColor(white: 0.035, alpha: 1), roughness: 0.62)
        case .rubber: return pbr(UIColor(white: 0.03, alpha: 1), roughness: 0.86)
        case .wheel: return pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.3, metalness: 0.6, clearCoat: 0.5)
        case .lampLens: return pbr(UIColor(white: 0.85, alpha: 1), roughness: 0.02, clearCoat: 1, opacity: 0.22)
        case .lampInner: return pbr(UIColor(white: 0.7, alpha: 1), roughness: 0.14, metalness: 1)
        case .lampGlow: return pbr(UIColor(white: 0.82, alpha: 1), roughness: 0.3)
        case .tailLens: return pbr(UIColor(red: 0.5, green: 0.02, blue: 0.03, alpha: 1), roughness: 0.05, clearCoat: 1, opacity: 0.88)
        case .amberLens: return pbr(UIColor(red: 0.85, green: 0.38, blue: 0.03, alpha: 1), roughness: 0.05, opacity: 0.8)
        case .interior: return pbr(UIColor(white: 0.045, alpha: 1), roughness: 0.7)
        case .brake: return pbr(UIColor(white: 0.32, alpha: 1), roughness: 0.4, metalness: 0.85)
        case .mirror: return pbr(UIColor(white: 0.9, alpha: 1), roughness: 0.02, metalness: 1)
        }
    }

    /// What lights up while the phone is in the car: the running lights white, the tail red.
    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }

    /// A soft shadow under the car, so it sits on something rather than floating.
    static let shadowImage: UIImage = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.75).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: 128, y: 128)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 128, options: [])
        }
    }()

    // MARK: Scene

    enum Presentation {
        /// The Devices card: three-quarter front, the car filling a wide, short frame.
        case card
        /// The car's page: the same pose, a touch closer and higher.
        case hero
        /// The lights' page: from above, front at the top, the body cut away at the waist so the
        /// cabin shows.
        case cutaway

        var distance: Float {
            switch self {
            case .card: return 6.9
            case .hero: return 7.4
            case .cutaway: return 3.3
            }
        }
        var height: Float {
            switch self {
            case .card: return 2.1
            case .hero: return 2.3
            case .cutaway: return 8.4
            }
        }
        var target: SCNVector3 { self == .cutaway ? SCNVector3(0, 0.3, -0.12) : SCNVector3(0, 0.62, 0) }
        /// The car's yaw at rest: the front left corner toward the viewer — or, cut away, the front
        /// away from it (at the top of the screen).
        var restYaw: Float { self == .cutaway ? .pi : -0.62 }
    }

    /// Hit-testing the cabin (to place lamps) looks only at these parts.
    static let cabinCategory = 1 << 2

    /// Where the body is cut for the cabin view: just under the window line.
    static let beltHeight: Float = 0.98

    /// Drops everything above the belt line (in car space — the car only ever turns about Y).
    private static let cutawayModifier = """
        float4 carPoint = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        if (carPoint.y > \(beltHeight)) { discard_fragment(); }
        """

    /// A self-contained scene: the car on its shadow, the wearables' studio light, a camera.
    @MainActor
    final class Live {
        let scene = SCNScene()
        let camera = SCNNode()
        let spinner = SCNNode()
        private var lit: [SCNNode] = []
        let hasModel: Bool
        private let spins: Bool
        private let spinSeconds: Double
        private var turnStartYaw: Float = 0
        /// Radians per point of drag.
        static let turnRate: Float = 0.012

        init(presentation: Presentation = .card, spin: Bool = true, spinSeconds: Double = 40, mesh: Mesh? = CarModel.bundled) {
            hasModel = mesh != nil
            spins = spin
            self.spinSeconds = spinSeconds
            scene.background.contents = UIColor.clear
            scene.lightingEnvironment.contents = RingModel.environment   // the wearables' shared studio
            scene.lightingEnvironment.intensity = 1.5
            scene.rootNode.addChildNode(spinner)
            spinner.eulerAngles.y = presentation.restYaw
            if spin { spinner.runAction(spinForever, forKey: "spin") }

            if let mesh {
                let shadow = SCNNode(geometry: SCNPlane(width: 3.0, height: 6.2))
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = CarModel.shadowImage
                m.writesToDepthBuffer = false
                shadow.geometry?.firstMaterial = m
                shadow.eulerAngles.x = -.pi / 2
                shadow.position.y = 0.005
                shadow.renderingOrder = -1
                spinner.addChildNode(shadow)

                for part in mesh.parts {
                    // Cut away, the windows go and the body stops at the waist.
                    if presentation == .cutaway, part.slot == .glass { continue }
                    let geometry = part.geometry.copy() as! SCNGeometry
                    geometry.firstMaterial = CarModel.material(for: part.slot)
                    if presentation == .cutaway, part.slot != .interior {
                        geometry.firstMaterial?.shaderModifiers = [.fragment: CarModel.cutawayModifier]
                        geometry.firstMaterial?.isDoubleSided = true   // the inside of the door skins shows now
                    }
                    let node = SCNNode(geometry: geometry)
                    if part.slot == .interior { node.categoryBitMask |= CarModel.cabinCategory }
                    // Glass and lenses after the solid body, so what is behind them shows.
                    if [.glass, .lampLens, .tailLens, .amberLens].contains(part.slot) { node.renderingOrder = 10 }
                    spinner.addChildNode(node)
                    let glowColor: UIColor? = switch part.slot {
                    case .lampGlow: UIColor(white: 1, alpha: 1)
                    case .tailLens: UIColor(red: 1, green: 0.08, blue: 0.06, alpha: 1)
                    default: nil
                    }
                    if let glowColor {
                        let glowGeometry = part.geometry.copy() as! SCNGeometry
                        glowGeometry.firstMaterial = CarModel.glow(glowColor)
                        let glow = SCNNode(geometry: glowGeometry)
                        glow.opacity = 0
                        glow.renderingOrder = 20
                        spinner.addChildNode(glow)
                        lit.append(glow)
                    }
                }
            }

            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 900, .white, SCNVector3(-0.75, 0.6, 0)),
                (.directional, 420, UIColor(red: 0.72, green: 0.82, blue: 1, alpha: 1), SCNVector3(-0.25, -2.4, 0)),
                (.directional, 380, .white, SCNVector3(-0.5, 2.9, 0)),
                (.ambient, 120, .white, SCNVector3Zero),
            ]
            for (type, intensity, color, euler) in lights {
                let light = SCNLight()
                light.type = type
                light.intensity = intensity
                light.color = color
                let n = SCNNode()
                n.light = light
                n.eulerAngles = euler
                scene.rootNode.addChildNode(n)
            }
            let lens = SCNCamera()
            lens.fieldOfView = 26
            lens.zNear = 0.1
            lens.zFar = 60
            camera.camera = lens
            camera.position = SCNVector3(0, presentation.height, presentation.distance)
            camera.look(at: presentation.target)
            scene.rootNode.addChildNode(camera)
        }

        private var spinForever: SCNAction {
            .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds))
        }

        // MARK: Turntable — a sideways drag turns the car about its vertical axis only.

        /// A drag started: hold the car where it is.
        func beginTurn() {
            spinner.removeAction(forKey: "spin")
            turnStartYaw = spinner.eulerAngles.y
        }

        /// `points` = the drag's sideways travel so far; right turns the front to the right.
        func turn(by points: CGFloat) {
            spinner.eulerAngles.y = turnStartYaw + Float(points) * Self.turnRate
        }

        /// Let go: coast on the drag's speed, then carry on turning by itself.
        func endTurn(velocity: CGFloat) {
            let coastAngle = CGFloat(Float(velocity) * Self.turnRate * 0.25)
            let coast = SCNAction.rotateBy(x: 0, y: coastAngle, z: 0, duration: 0.7)
            coast.timingMode = .easeOut
            spinner.runAction(spins ? .sequence([coast, spinForever]) : coast, forKey: "spin")
        }

        func setLit(_ on: Bool) {
            let fade = SCNAction.fadeOpacity(to: on ? 1 : 0, duration: 0.5)
            fade.timingMode = .easeOut
            lit.forEach { $0.runAction(fade, forKey: "lit") }
        }
    }
}

/// The car rendered live, like the dashcam on its card.
struct CarSceneView: View {
    var presentation: CarModel.Presentation = .card
    var spin = true
    var lit = false
    var spinSeconds: Double = 40
    var animatesAnywhere = false
    /// Sideways drags turn the car; it keeps turning on its own once let go.
    var turnable = false

    @State private var live: CarModel.Live?
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        spin && scenePhase == .active
            && (animatesAnywhere || (router.map { $0.selectedTab == .devices } ?? true))
    }

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating,
                            onHorizontalPan: turnable ? { pan in Self.turn(live, pan) } : nil)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard live == nil else { return }
            let scene = CarModel.Live(presentation: presentation, spin: spin, spinSeconds: spinSeconds)
            if lit { scene.setLit(true) }
            live = scene
        }
        .onChange(of: lit) { _, on in live?.setLit(on) }
    }

    private static func turn(_ live: CarModel.Live, _ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: live.beginTurn()
        case .changed: live.turn(by: pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed: live.endTurn(velocity: pan.velocity(in: pan.view).x)
        default: break
        }
    }
}
