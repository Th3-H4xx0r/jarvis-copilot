import CoreImage
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

    /// Whether the app has the car at all — without loading it (the views ask this on every render).
    static let hasBundledModel = Bundle.main.url(forResource: "Camry", withExtension: "bin") != nil

    /// The car shipped with the app; nil leaves the card without a model.
    static let bundled: Mesh? = Bundle.main.url(forResource: "Camry", withExtension: "bin")
        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        .flatMap(mesh(from:))

    // MARK: Materials

    /// Dark Cosmos — Toyota 8Z3, new for 2026: a deep, hazy slate blue with a violet cast, matched
    /// against Toyota's own picture of the SE.
    /// Darker than the photo's raw pixels on purpose: the app shows it on black, where the same
    /// paint reads much lighter than on Toyota's white page.
    static let darkCosmos = UIColor(red: 0.088, green: 0.104, blue: 0.2, alpha: 1)

    private static func pbr(_ color: UIColor, roughness: CGFloat, metalness: CGFloat = 0,
                            clearCoat: CGFloat = 0, clearCoatRoughness: CGFloat = 0.04, opacity: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = clearCoatRoughness
        if opacity < 1 {
            m.transparency = opacity
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
        }
        return m
    }

    static func material(for slot: Slot) -> SCNMaterial {
        switch slot {
        case .paint: return pbr(darkCosmos, roughness: 0.38, metalness: 0.45, clearCoat: 0.8, clearCoatRoughness: 0.06)
        // Tinted and only half as glossy: a full clear coat mirrored the softbox as a white sheet.
        case .glass: return pbr(UIColor(white: 0.01, alpha: 1), roughness: 0.06, clearCoat: 0.5, opacity: 0.86)
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

    private static func blurred(_ image: UIImage, sigma: Double) -> UIImage {
        guard let ci = CIImage(image: image) else { return image }
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
        guard let cg = CIContext().createCGImage(out, from: ci.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    /// A car photo studio as an equirectangular environment: a dark room, a large softbox overhead
    /// and two pairs of long strip lights at the horizon — so the paint shows long, soft reflections
    /// along the body lines instead of one hard hotspot.
    ///
    /// 2048 × 1024 and kept bright in the image itself (the scene scales it down): a dark 8-bit room
    /// multiplied up showed as stepped bands in the glass and paint.
    static let studioEnvironment: UIImage = {
        let size = CGSize(width: 2048, height: 1024)
        let raw = UIGraphicsImageRenderer(size: size).image { r in
            let ctx = r.cgContext
            let colors = [UIColor(white: 0.24, alpha: 1).cgColor, UIColor(white: 0.13, alpha: 1).cgColor,
                          UIColor(white: 0.06, alpha: 1).cgColor, UIColor(white: 0.04, alpha: 1).cgColor] as CFArray
            if let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 0.55, 1]) {
                ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 560, y: 90, width: 928, height: 180))                 // overhead softbox
            for y in [size.height / 2 - 92, size.height / 2 - 14] {                 // strip lights
                ctx.fill(CGRect(x: 80, y: y, width: 760, height: 24))
                ctx.fill(CGRect(x: 1208, y: y, width: 760, height: 24))
            }
            UIColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 1).setFill()          // cool rim
            ctx.fill(CGRect(x: 0, y: size.height / 2 - 130, width: 70, height: 110))
            ctx.fill(CGRect(x: size.width - 70, y: size.height / 2 - 130, width: 70, height: 110))
        }
        return blurred(raw, sigma: 7)
    }()

    /// The car's contact shadow: a soft rounded footprint, so it sits on the floor.
    static let shadowImage: UIImage = {
        let size = CGSize(width: 256, height: 512)
        let raw = UIGraphicsImageRenderer(size: size).image { r in
            UIColor(white: 0, alpha: 0.85).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40), cornerRadius: 60).fill()
        }
        return blurred(raw, sigma: 18)
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

    /// Load the mesh and build the studio and shadow images now, off the main thread, so the first
    /// car on screen doesn't stall it (at launch).
    static func warmUp() {
        Task.detached(priority: .utility) {
            _ = CarModel.bundled
            _ = CarModel.studioEnvironment
            _ = CarModel.shadowImage
        }
    }

    /// Builds a scene off the main thread — 400 k triangles and their materials — for a view to
    /// show once it's ready, instead of in the middle of a navigation.
    static func build(_ presentation: Presentation, spin: Bool = true, spinSeconds: Double = 40) async -> Live {
        await Task.detached(priority: .userInitiated) {
            Live(presentation: presentation, spin: spin, spinSeconds: spinSeconds)
        }.value
    }

    /// A self-contained scene: the car on its shadow, the studio light, a camera. Not tied to the
    /// main actor: it's plain SceneKit, built on a background thread (`build`) and then shown.
    final class Live: @unchecked Sendable {
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
            scene.lightingEnvironment.contents = CarModel.studioEnvironment   // a car photo studio
            scene.lightingEnvironment.intensity = 1.6
            scene.rootNode.addChildNode(spinner)
            spinner.eulerAngles.y = presentation.restYaw
            if spin { spinner.runAction(spinForever, forKey: "spin") }

            if let mesh {
                let shadow = SCNNode(geometry: SCNPlane(width: 2.6, height: 5.4))
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

            // The studio does the lighting; a soft key from above-front shapes it, nothing hard enough
            // to burn a hotspot into the clear coat.
            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 200, .white, SCNVector3(-1.1, 0.4, 0)),
                (.ambient, 40, .white, SCNVector3Zero),
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
            // HDR tone mapping only: highlights fade instead of clipping. No ambient occlusion or
            // bloom — they render at reduced resolution and left the edges jagged.
            lens.wantsHDR = true
            lens.wantsExposureAdaptation = false
            lens.exposureOffset = -0.15
            lens.whitePoint = 2.2
            lens.minimumExposure = -3
            lens.maximumExposure = 3
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
    /// False while another page covers it: the Devices card kept drawing at 30 fps under the car's
    /// own page, two full car scenes at once.
    @State private var onScreen = false
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        spin && onScreen && scenePhase == .active
            && (animatesAnywhere || (router.map { $0.selectedTab == .devices } ?? true))
    }

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating,
                            onHorizontalPan: turnable ? { pan in Self.turn(live, pan) } : nil)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.3), value: live != nil)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        // Built off the main thread: opening a page with the car doesn't stall its transition.
        .task {
            guard live == nil else { return }
            let scene = await CarModel.build(presentation, spin: spin, spinSeconds: spinSeconds)
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
