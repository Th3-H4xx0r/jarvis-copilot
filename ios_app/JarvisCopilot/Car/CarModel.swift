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
        /// The Face ID approval card: mostly side-on (a little of the front still showing), centred
        /// in a short frame with room under the wheels for the action's badge. It turns into this
        /// pose once (`Live.enter`) and then holds still.
        case approval

        var distance: Float {
            switch self {
            case .card: return 6.9
            case .hero: return 7.4
            case .cutaway: return 3.3
            case .approval: return 8.5
            }
        }
        var height: Float {
            switch self {
            case .card: return 2.1
            case .hero: return 2.3
            case .cutaway: return 8.4
            case .approval: return 2.1
            }
        }
        /// Slides the camera and its target sideways together: a car turned toward the viewer sits
        /// off centre (its near front corner is bigger), and this brings it back to the middle.
        var pan: Float { self == .approval ? -0.14 : 0 }
        var target: SCNVector3 {
            switch self {
            case .cutaway: return SCNVector3(0, 0.3, -0.12)
            case .approval: return SCNVector3(pan, 0.47, 0)
            case .card, .hero: return SCNVector3(0, 0.62, 0)
            }
        }
        /// The car's yaw at rest: the front left corner toward the viewer (the approval card further
        /// round, nearly side-on) — or, cut away, the front away from it (at the top of the screen).
        var restYaw: Float {
            switch self {
            case .cutaway: return .pi
            case .approval: return -1.1
            case .card, .hero: return -0.62
            }
        }
    }

    /// Hit-testing the cabin (to place lamps) looks only at these parts.
    static let cabinCategory = 1 << 2

    /// Where the body is cut for the cabin view: just under the window line.
    static let beltHeight: Float = 0.98

    /// The hero car's body can be sliced at any height (the cabin view lowers it from above the roof
    /// to the belt line). Same test as the cutaway, with the height as an animatable argument.
    static let sliceModifier = """
        #pragma arguments
        float sliceHeight;
        #pragma body
        float4 carPoint = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        if (carPoint.y > sliceHeight) { discard_fragment(); }
        """
    /// Above the roof: nothing is cut.
    static let noSlice: Float = 3

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
    static func build(_ presentation: Presentation, spin: Bool = true, spinSeconds: Double = 40,
                      canSlice: Bool = false) async -> Live {
        await Task.detached(priority: .userInitiated) {
            Live(presentation: presentation, spin: spin, spinSeconds: spinSeconds, canSlice: canSlice)
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
        private let presentation: Presentation
        /// The hero's body parts, sliced for the cabin view; and its windows, which fade for it.
        private var sliceable: [SCNMaterial] = []
        private var windows: [SCNNode] = []
        /// Main thread only: whether the cabin view is open (the render thread only writes the
        /// shader's height while a slice animates).
        private var sliceOpen = false
        /// The fill light, raised for the top views: Dark Cosmos from straight above read as black.
        private var fill: SCNLight?
        /// Where the stage animations are heading (the hero's screens move it).
        private(set) var stage: Stage = .hero
        /// Car-space landmarks for the top views' labels: wheel centres, windscreen and rear window.
        let landmarks: Landmarks
        /// Radians per point of drag.
        static let turnRate: Float = 0.012

        /// `canSlice`: the screens' car, which opens into the cabin. The page's turning car never
        /// does, so it doesn't pay for the slice shader (a discard on every body pixel).
        init(presentation: Presentation = .card, spin: Bool = true, spinSeconds: Double = 40,
             canSlice: Bool = false, mesh: Mesh? = CarModel.bundled) {
            hasModel = mesh != nil
            spins = spin
            self.spinSeconds = spinSeconds
            self.presentation = presentation
            landmarks = Landmarks(mesh: mesh)
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
                    if canSlice, part.slot != .interior, part.slot != .glass, let material = geometry.firstMaterial {
                        material.shaderModifiers = [.fragment: CarModel.sliceModifier]
                        material.setValue(NSNumber(value: CarModel.noSlice), forKey: "sliceHeight")
                        sliceable.append(material)
                    }
                    let node = SCNNode(geometry: geometry)
                    if canSlice, part.slot == .glass { windows.append(node) }
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
                if type == .ambient { fill = light }
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
            camera.position = SCNVector3(presentation.pan, presentation.height, presentation.distance)
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

        // MARK: Entrance — the approval card's car turns into its pose once, then holds still.

        /// How far round from its rest pose the car waits (head-on), and how long the turn takes.
        static let entranceTurn: Float = 1.1
        static let entranceTime: Double = 1.8

        /// Before it's shown: wait `entranceTurn` round from the rest pose.
        func readyEntrance() {
            spinner.removeAction(forKey: "spin")
            spinner.eulerAngles.y = presentation.restYaw + Self.entranceTurn
        }

        /// Turn into the rest pose: a gentle start and a long, soft settle.
        func enter() {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = Self.entranceTime
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            spinner.eulerAngles.y = presentation.restYaw
            SCNTransaction.commit()
        }

        // MARK: Stages — a screen's car glides from the hero pose to the top view and into the cabin.

        enum Stage { case hero, top, cabin }

        /// Camera heights above the ground for the top views (26° lens): the whole car, then the cabin.
        static let topHeight: Float = 13
        static let cabinHeight: Float = 11
        /// Studio and fill light for the hero, and for the views from above (brighter: the roof and
        /// the cabin face the camera, away from the studio's key light).
        private static let heroLight: (studio: CGFloat, fill: CGFloat) = (1.6, 40)
        private static let topLight: (studio: CGFloat, fill: CGFloat) = (3.4, 320)
        private static let glide: Double = 0.9
        private static let sliceTime: Double = 0.6

        /// Bumped by every move: a delayed step or a completion from an earlier move sees it changed
        /// and stands down, so quick back-and-forth can't leave the car half way between stages.
        private var generation = 0

        /// Move to a stage: the car stops turning and turns front-up as the camera rises overhead;
        /// the cabin then slices the roof away from the top down. `settled` runs on the main thread
        /// once the car is there (not if another move replaced this one).
        func go(to target: Stage, animated: Bool = true, settled: (() -> Void)? = nil) {
            guard presentation == .hero, hasModel, target != stage else {
                settled?()
                return
            }
            let from = stage
            stage = target
            generation += 1
            let move = generation
            guard animated else {
                applyNow(target)
                settled?()
                return
            }
            let done: () -> Void = { [weak self] in
                guard let self, self.generation == move else { return }
                settled?()
            }
            switch target {
            case .hero:
                let wait = sliceOpen ? Self.sliceTime : 0
                slice(open: false, duration: Self.sliceTime)
                moveCamera(to: target, duration: Self.glide, delay: wait, move: move) { [weak self] in
                    self?.resumeSpinIfHero()
                    done()
                }
            case .top:
                spinner.removeAction(forKey: "spin")
                let closing = sliceOpen
                slice(open: false, duration: Self.sliceTime)
                moveCamera(to: target, duration: closing ? Self.sliceTime : Self.glide, delay: 0, move: move, then: done)
            case .cabin:
                spinner.removeAction(forKey: "spin")
                moveCamera(to: target, duration: from == .hero ? Self.glide : Self.sliceTime * 0.6, delay: 0, move: move) {
                    [weak self] in
                    guard let self, self.generation == move else { return }
                    self.slice(open: true, duration: Self.sliceTime, then: done)
                }
            }
        }

        /// Stop or restart the hero's slow turn (a covered page shouldn't keep drawing a turning car).
        func setSpinning(_ on: Bool) {
            if on {
                resumeSpinIfHero()
            } else {
                spinner.removeAction(forKey: "spin")
            }
        }

        /// The camera pose and car yaw for a stage.
        private func pose(for target: Stage) -> (position: SCNVector3, orientation: SCNQuaternion, yaw: Float) {
            let node = SCNNode()
            switch target {
            case .hero:
                node.position = SCNVector3(presentation.pan, presentation.height, presentation.distance)
                node.look(at: presentation.target)
                return (node.position, node.orientation, presentation.restYaw)
            case .top, .cabin:
                let centre = landmarks.centreZ
                // Straight down, the front at the top of the screen (screen up = world -Z).
                node.position = SCNVector3(0, target == .top ? Self.topHeight : Self.cabinHeight, -centre)
                node.look(at: SCNVector3(0, 0, -centre), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
                return (node.position, node.orientation, .pi)
            }
        }

        /// The yaw nearest the car's current one, so it never turns the long way round.
        private func nearest(_ yaw: Float) -> Float {
            let now = spinner.presentation.eulerAngles.y
            return yaw + ((now - yaw) / (2 * .pi)).rounded() * 2 * .pi
        }

        private func resumeSpinIfHero() {
            guard stage == .hero, spins, spinner.action(forKey: "spin") == nil else { return }
            spinner.runAction(spinForever, forKey: "spin")
        }

        /// Without animation (tests, a screen opened before the car was built): straight there.
        private func setLight(for target: Stage) {
            let light = target == .hero ? Self.heroLight : Self.topLight
            scene.lightingEnvironment.intensity = light.studio
            fill?.intensity = light.fill
        }

        private func applyNow(_ target: Stage) {
            spinner.removeAction(forKey: "spin")
            spinner.removeAction(forKey: "slice")
            let (position, orientation, yaw) = pose(for: target)
            camera.position = position
            camera.orientation = orientation
            setLight(for: target)
            spinner.eulerAngles.y = nearest(yaw)
            let open = target == .cabin
            sliceOpen = open
            setSlice(open ? CarModel.beltHeight : CarModel.noSlice)
            sliceable.forEach { $0.isDoubleSided = open }
            windows.forEach { $0.removeAction(forKey: "window"); $0.opacity = open ? 0 : 1 }
            resumeSpinIfHero()
        }

        /// Only the shader's value — safe from SceneKit's render thread.
        private func setSlice(_ height: Float) {
            sliceable.forEach { $0.setValue(NSNumber(value: height), forKey: "sliceHeight") }
        }

        private func moveCamera(to target: Stage, duration: Double, delay: Double, move: Int,
                                then done: (() -> Void)? = nil) {
            let (position, orientation, yaw) = pose(for: target)
            let animate = { [weak self] in
                guard let self, self.generation == move else { return }
                let finalYaw = self.nearest(yaw)
                self.spinner.eulerAngles.y = self.spinner.presentation.eulerAngles.y
                SCNTransaction.begin()
                SCNTransaction.animationDuration = duration
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                SCNTransaction.completionBlock = { [weak self] in
                    guard let self, self.generation == move else { return }
                    done?()
                }
                self.camera.position = position
                self.camera.orientation = orientation
                self.spinner.eulerAngles.y = finalYaw
                self.setLight(for: target)
                SCNTransaction.commit()
            }
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: animate)
            } else {
                animate()
            }
        }

        /// Lowers the slice from above the roof to the belt line (the cabin shows) or raises it back.
        /// `then` runs on the main thread when it's done.
        private func slice(open: Bool, duration: Double, then done: (() -> Void)? = nil) {
            guard !sliceable.isEmpty, sliceOpen != open else {
                done?()
                return
            }
            sliceOpen = open
            let from = open ? CarModel.noSlice : CarModel.beltHeight
            let to = open ? CarModel.beltHeight : CarModel.noSlice
            if open { sliceable.forEach { $0.isDoubleSided = true } }   // the door skins' insides show
            let fade = SCNAction.fadeOpacity(to: open ? 0 : 1, duration: duration)
            windows.forEach { $0.runAction(fade, forKey: "window") }
            let materials = sliceable
            let action = SCNAction.customAction(duration: duration) { [weak self] _, elapsed in
                let t = duration > 0 ? Float(min(max(elapsed / CGFloat(duration), 0), 1)) : 1
                let eased = t * t * (3 - 2 * t)
                self?.setSlice(from + (to - from) * eased)
            }
            let finish = SCNAction.run { [weak self] _ in
                self?.setSlice(to)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sliceOpen == open else { return }
                    if !open { materials.forEach { $0.isDoubleSided = false } }
                    done?()
                }
            }
            spinner.runAction(.sequence([action, finish]), forKey: "slice")
        }

        /// Where a car-space point lands in a view of `size`, looking down from a top stage.
        func topViewPoint(_ point: SIMD3<Float>, in size: CGSize, stage: Stage) -> CGPoint {
            Self.topViewPoint(point, in: size, height: stage == .cabin ? Self.cabinHeight : Self.topHeight,
                              centreZ: landmarks.centreZ)
        }

        /// Pinhole projection for the straight-down camera: the front (+Z) up, the driver's side
        /// (+X) on the left — his car is left-hand drive.
        static func topViewPoint(_ point: SIMD3<Float>, in size: CGSize, height: Float, centreZ: Float) -> CGPoint {
            guard size.width > 0, size.height > 0 else { return .zero }
            let halfView = tan(Float(26.0 / 2 * .pi / 180))
            let depth = max(height - point.y, 0.1)
            let aspect = Float(size.width / size.height)
            let up = (point.z - centreZ) / (depth * halfView)
            let right = -point.x / (depth * halfView * aspect)
            return CGPoint(x: size.width * CGFloat(0.5 + right / 2), y: size.height * CGFloat(0.5 - up / 2))
        }

        func setLit(_ on: Bool) {
            let fade = SCNAction.fadeOpacity(to: on ? 1 : 0, duration: 0.5)
            fade.timingMode = .easeOut
            lit.forEach { $0.runAction(fade, forKey: "lit") }
        }
    }
}

/// Car-space places the top views label: the wheel centres, the windscreen and the rear window.
struct Landmarks {
    var wheels: [String: SIMD3<Float>]   // fl fr rl rr
    var windscreen: SIMD3<Float>
    var rearWindow: SIMD3<Float>
    var centreZ: Float
    var length: Float

    init(mesh: CarModel.Mesh?) {
        let lo = mesh?.min ?? SIMD3(-0.92, 0, -2.46), hi = mesh?.max ?? SIMD3(0.92, 1.44, 2.46)
        centreZ = (lo.z + hi.z) / 2
        length = hi.z - lo.z
        func bounds(_ slot: CarModel.Slot) -> (SIMD3<Float>, SIMD3<Float>)? {
            guard let geometry = mesh?.parts.first(where: { $0.slot == slot })?.geometry else { return nil }
            let (a, b) = geometry.boundingBox
            return (SIMD3(Float(a.x), Float(a.y), Float(a.z)), SIMD3(Float(b.x), Float(b.y), Float(b.z)))
        }
        // All four rims are one part: its box spans both axles and both sides.
        let (wl, wh) = bounds(.wheel) ?? (SIMD3(-0.86, 0, lo.z + 0.55), SIMD3(0.86, 0.72, hi.z - 0.95))
        let radius = (wh.y - wl.y) / 2
        let side = max(wh.x - 0.1, 0.4)
        let front = wh.z - radius, rear = wl.z + radius, y = wl.y + radius
        // +X is the driver's side: left on his left-hand-drive car.
        wheels = ["fl": SIMD3(side, y, front), "fr": SIMD3(-side, y, front),
                  "rl": SIMD3(side, y, rear), "rr": SIMD3(-side, y, rear)]
        let (gl, gh) = bounds(.glass) ?? (SIMD3(-0.8, 0.9, lo.z + 0.6), SIMD3(0.8, 1.44, hi.z - 1.3))
        windscreen = SIMD3(0, (gl.y + gh.y) / 2, gh.z - 0.32)
        rearWindow = SIMD3(0, (gl.y + gh.y) / 2, gl.z + 0.3)
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
    /// Once shown, the car turns into its rest pose (`Live.enter`), then holds still.
    var turnsIntoPlace = false

    @State private var live: CarModel.Live?
    /// True while the car turns into place: the view renders only while it moves.
    @State private var entering = false
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
                // 60 fps, not the wearables' 30: a turning (or dragged) car at 30 fps looks choppy
                // next to the rest of a 120 Hz screen.
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating || entering,
                            preferredFramesPerSecond: 60,
                            onHorizontalPan: turnable ? { pan in Self.turn(live, pan) } : nil,
                            onFirstFrame: turnsIntoPlace ? { turnIn(live) } : nil)
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
            if turnsIntoPlace {
                scene.readyEntrance()
                entering = true
            }
            live = scene
        }
        .onChange(of: lit) { _, on in live?.setLit(on) }
    }

    /// The first frame is on screen: wait out the fade-in, then turn, so the whole turn is seen.
    /// (Timed from the view appearing, the turn was mostly over before the car showed on a phone.)
    private func turnIn(_ live: CarModel.Live) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            live.enter()
            try? await Task.sleep(for: .seconds(CarModel.Live.entranceTime + 0.1))
            entering = false
        }
    }

    static func turn(_ live: CarModel.Live, _ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: live.beginTurn()
        case .changed: live.turn(by: pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed: live.endTurn(velocity: pan.velocity(in: pan.view).x)
        default: break
        }
    }
}
