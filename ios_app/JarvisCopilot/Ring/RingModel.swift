import SceneKit
import UIKit

/// A procedural Colmi R12, after the real ring: a glossy gunmetal shell with polished inner lips,
/// and a clear resin band over the segmented circuit board — black chips, pale metal parts,
/// passives, rows of solder, and the round sensor contact — as you see it looking inside.
///
/// The ring's axis is Y. The profile is a rounded rectangle in (radius, height) lathed around
/// that axis; the inner face is split off so the resin and the board behind it can differ.
enum RingModel {
    // A real R12 is ~20 mm across, ~7.5 mm wide, with a ~2.5 mm wall.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.78
    static let width: CGFloat = 0.72
    /// Leans the ring toward the camera so the inside — board, sensor, LEDs — shows.
    static let defaultTilt: Float = 0.95
    private static let fillet: CGFloat = 0.09
    /// How far behind the resin the board sits.
    private static let boardDepth: CGFloat = 0.03

    private struct ProfilePoint {
        var r: CGFloat
        var y: CGFloat
        var nr: CGFloat
        var ny: CGFloat
    }

    // MARK: Profile

    private static func arc(r cr: CGFloat, y cy: CGFloat, radius: CGFloat,
                            from a0: CGFloat, to a1: CGFloat, steps: Int) -> [ProfilePoint] {
        (0...steps).map { i in
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            return ProfilePoint(r: cr + radius * cos(a), y: cy + radius * sin(a), nr: cos(a), ny: sin(a))
        }
    }

    private static func line(from p0: (CGFloat, CGFloat), to p1: (CGFloat, CGFloat),
                             normal: (CGFloat, CGFloat), steps: Int) -> [ProfilePoint] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return ProfilePoint(r: p0.0 + (p1.0 - p0.0) * t, y: p0.1 + (p1.1 - p0.1) * t, nr: normal.0, ny: normal.1)
        }
    }

    /// The top, outer face and bottom, traced clockwise from the top lip to the bottom lip.
    private static var shellProfile: [ProfilePoint] {
        let f = fillet, h = width / 2, ri = innerRadius, ro = outerRadius
        var points = line(from: (ri + f, h), to: (ro - f, h), normal: (0, 1), steps: 4)
        points += arc(r: ro - f, y: h - f, radius: f, from: .pi / 2, to: 0, steps: 10).dropFirst()
        points += line(from: (ro, h - f), to: (ro, -h + f), normal: (1, 0), steps: 8).dropFirst()
        points += arc(r: ro - f, y: -h + f, radius: f, from: 0, to: -.pi / 2, steps: 10).dropFirst()
        points += line(from: (ro - f, -h), to: (ri + f, -h), normal: (0, -1), steps: 4).dropFirst()
        return points
    }

    /// The rounded lips between the shell and the resin — polished metal on the real ring.
    private static var lips: [[ProfilePoint]] {
        let f = fillet, h = width / 2, ri = innerRadius
        return [arc(r: ri + f, y: h - f, radius: f, from: .pi, to: .pi / 2, steps: 8),
                arc(r: ri + f, y: -h + f, radius: f, from: -.pi / 2, to: -.pi, steps: 8)]
    }

    /// The inner face, bottom to top, facing the hole.
    private static var innerBand: [ProfilePoint] {
        let h = width / 2 - fillet
        return line(from: (innerRadius, -h), to: (innerRadius, h), normal: (-1, 0), steps: 6)
    }

    /// Lathes a clockwise profile; triangles wind so the given normals face out.
    private static func lathe(_ profile: [ProfilePoint], segments: Int = 96, radiusOffset: CGFloat = 0) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        let yMin = profile.map(\.y).min() ?? 0
        let yMax = profile.map(\.y).max() ?? 1
        for point in profile {
            for s in 0...segments {
                let a = 2 * CGFloat.pi * CGFloat(s) / CGFloat(segments)
                let c = cos(a), sn = sin(a)
                let r = point.r + radiusOffset
                positions.append(SCNVector3(Float(r * c), Float(point.y), Float(r * sn)))
                normals.append(SCNVector3(Float(point.nr * c), Float(point.ny), Float(point.nr * sn)))
                uvs.append(CGPoint(x: CGFloat(s) / CGFloat(segments), y: (yMax - point.y) / max(0.0001, yMax - yMin)))
            }
        }
        var indices: [Int32] = []
        let row = segments + 1
        for i in 0..<(profile.count - 1) {
            for s in 0..<segments {
                let a = Int32(i * row + s), b = Int32(i * row + s + 1)
                let c = Int32((i + 1) * row + s), d = Int32((i + 1) * row + s + 1)
                indices += [a, b, c, b, d, c]
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                      SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: Textures

    /// The board as seen through the resin, and a metalness map drawn from the same layout.
    /// u runs around the band (the sensor sits at u = 0.75), v across it.
    static let board = (color: drawBoard(metalness: false), metalness: drawBoard(metalness: true))

    private static func drawBoard(metalness: Bool) -> UIImage {
        let size = CGSize(width: 2400, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            // Both passes consume the same random sequence, so the maps line up.
            var seed: UInt32 = 0x9E37_79B9
            func random() -> CGFloat {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return CGFloat(seed >> 8) / CGFloat(1 << 24)
            }
            func fill(_ rect: CGRect, _ color: UIColor, metallic: CGFloat = 0) {
                (metalness ? UIColor(white: metallic, alpha: 1) : color).setFill()
                g.fill(rect)
            }
            let solder = UIColor(white: 0.74, alpha: 1)
            let package = UIColor(white: 0.045, alpha: 1)
            fill(CGRect(origin: .zero, size: size), UIColor(red: 0.03, green: 0.038, blue: 0.035, alpha: 1))

            let sensorX = size.width * 0.75
            let segmentWidth = size.width / 12
            for index in 0..<12 {
                let x0 = CGFloat(index) * segmentWidth
                // Flex joint between rigid sections.
                fill(CGRect(x: x0, y: 0, width: 8, height: size.height), UIColor(white: 0.09, alpha: 1))
                // Vias along both edges.
                var vx = x0 + 16
                while vx < x0 + segmentWidth - 12 {
                    fill(CGRect(x: vx, y: 9, width: 4, height: 4), solder, metallic: 1)
                    fill(CGRect(x: vx, y: size.height - 13, width: 4, height: 4), solder, metallic: 1)
                    vx += 13
                }
                // A column of solder dots.
                let columnX = x0 + 20 + random() * (segmentWidth - 40)
                var dy: CGFloat = 36
                while dy < size.height - 36 {
                    fill(CGRect(x: columnX, y: dy, width: 3, height: 3), solder, metallic: 1)
                    dy += 8
                }
                // Passives: small bodies with metal end caps.
                for _ in 0..<14 {
                    let vertical = random() > 0.5
                    let w: CGFloat = vertical ? 7 : 15, h: CGFloat = vertical ? 15 : 7
                    let rect = CGRect(x: x0 + 16 + random() * (segmentWidth - 34),
                                      y: 22 + random() * (size.height - 44 - h), width: w, height: h)
                    fill(rect, UIColor(red: 0.30, green: 0.27, blue: 0.23, alpha: 1))
                    if vertical {
                        fill(CGRect(x: rect.minX, y: rect.minY, width: w, height: 3), solder, metallic: 1)
                        fill(CGRect(x: rect.minX, y: rect.maxY - 3, width: w, height: 3), solder, metallic: 1)
                    } else {
                        fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: h), solder, metallic: 1)
                        fill(CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: h), solder, metallic: 1)
                    }
                }
                // Around the sensor the raised parts take over.
                guard abs(x0 + segmentWidth / 2 - sensorX) >= segmentWidth else { continue }
                let half = (segmentWidth - 30) / 2
                for slot in 0..<2 {
                    let left = x0 + 18 + CGFloat(slot) * half
                    if slot == 1, random() > 0.45 {
                        // Crystal or shielded part: a pale metal square.
                        let side = 30 + random() * 24
                        let square = CGRect(x: left + random() * (half - side - 8),
                                            y: 26 + random() * (size.height - 52 - side), width: side, height: side)
                        fill(square, UIColor(red: 0.62, green: 0.58, blue: 0.50, alpha: 1), metallic: 0.85)
                        fill(square.insetBy(dx: 6, dy: 6), UIColor(red: 0.52, green: 0.48, blue: 0.41, alpha: 1),
                             metallic: 0.85)
                    } else {
                        // Chip: a black package with pads down both sides.
                        let w = 34 + random() * (half - 50), h = 44 + random() * 76
                        let chip = CGRect(x: left + 6 + random() * (half - w - 14),
                                          y: 24 + random() * (size.height - 48 - h), width: w, height: h)
                        fill(chip.insetBy(dx: -2, dy: -2), UIColor(white: 0.15, alpha: 1))
                        fill(chip, package)
                        var py = chip.minY + 6
                        while py < chip.maxY - 6 {
                            fill(CGRect(x: chip.minX - 6, y: py, width: 5, height: 3), solder, metallic: 1)
                            fill(CGRect(x: chip.maxX + 1, y: py, width: 5, height: 3), solder, metallic: 1)
                            py += 9
                        }
                    }
                }
            }
        }
    }

    /// A soft studio environment so the lacquer has something to reflect.
    static let environment: UIImage = {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor, UIColor(white: 0.24, alpha: 1).cgColor,
                          UIColor(white: 0.02, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(white: 1, alpha: 0.9).setFill()
            context.cgContext.fill(CGRect(x: 40, y: 16, width: 38, height: 30))
            context.cgContext.fill(CGRect(x: 172, y: 22, width: 24, height: 22))
        }
    }()

    // MARK: Materials

    private static func shellMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        m.metalness.contents = 0.7
        m.roughness.contents = 0.16
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.04
        return m
    }

    private static func resinMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 1, alpha: 0.08)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.03
        m.transparencyMode = .dualLayer
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }

    private static func circuitMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = board.color
        m.diffuse.mipFilter = .linear
        m.metalness.contents = board.metalness
        m.metalness.mipFilter = .linear
        m.roughness.contents = 0.32
        return m
    }

    private static func metalMaterial(_ color: UIColor = UIColor(white: 0.8, alpha: 1),
                                      roughness: CGFloat = 0.2) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = roughness
        return m
    }

    private static func plasticMaterial(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: white, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.35
        return m
    }

    private static func ledMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        m.emission.contents = color
        m.emission.intensity = Live.idleLED
        return m
    }

    // MARK: Assembly

    struct Parts {
        /// Tilt and scale.
        let pivot: SCNNode
        /// Turntable, about the ring's own axis.
        let spinner: SCNNode
        let leds: [SCNNode]
        let glow: SCNNode
    }

    /// Puts `node` (built facing +Z, toward the finger) on the board behind the resin, `along`
    /// radians around the band from the sensor and `y` across it.
    private static func mount(_ node: SCNNode, along: Float, y: Float, thickness: CGFloat) -> SCNNode {
        let holder = SCNNode()
        holder.eulerAngles.y = along
        node.position = SCNVector3(0, y, Float(-(innerRadius + boardDepth - thickness / 2)))
        holder.addChildNode(node)
        return holder
    }

    /// The round contact on the inner face: a polished ring around a white ring and a black centre.
    private static func sensorContact() -> SCNNode {
        let node = SCNNode()
        func add(_ geometry: SCNGeometry, z: Float) {
            let part = SCNNode(geometry: geometry)
            part.eulerAngles.x = .pi / 2  // Y-axis primitives turned to face +Z
            part.position.z = z
            node.addChildNode(part)
        }
        let base = SCNCylinder(radius: 0.078, height: 0.012)
        base.materials = [plasticMaterial(white: 0.02)]
        add(base, z: 0)
        let outer = SCNTorus(ringRadius: 0.064, pipeRadius: 0.012)
        outer.materials = [metalMaterial(roughness: 0.12)]
        add(outer, z: 0.005)
        let ceramic = SCNTorus(ringRadius: 0.036, pipeRadius: 0.013)
        ceramic.materials = [plasticMaterial(white: 0.9)]
        add(ceramic, z: 0.004)
        return node
    }

    static func makeNode() -> Parts {
        let root = SCNNode()

        let shell = lathe(shellProfile)
        shell.materials = [shellMaterial()]
        root.addChildNode(SCNNode(geometry: shell))

        for lip in lips {
            let geometry = lathe(lip)
            geometry.materials = [metalMaterial(UIColor(white: 0.55, alpha: 1), roughness: 0.1)]
            root.addChildNode(SCNNode(geometry: geometry))
        }

        let board = lathe(innerBand, radiusOffset: boardDepth)
        board.materials = [circuitMaterial()]
        root.addChildNode(SCNNode(geometry: board))

        let resin = lathe(innerBand)
        resin.materials = [resinMaterial()]
        let resinNode = SCNNode(geometry: resin)
        resinNode.renderingOrder = 10
        root.addChildNode(resinNode)

        // The sensor contact faces the camera before the ring spins, with raised parts around it.
        root.addChildNode(mount(sensorContact(), along: 0, y: 0, thickness: 0.024))
        let raised: [(along: Float, y: Float, width: CGFloat, height: CGFloat, depth: CGFloat, material: SCNMaterial)] = [
            (-0.20, 0.04, 0.075, 0.08, 0.012, plasticMaterial(white: 0.04)),
            (-0.33, -0.07, 0.055, 0.055, 0.008, metalMaterial(UIColor(red: 0.62, green: 0.58, blue: 0.5, alpha: 1), roughness: 0.35)),
            (0.19, -0.05, 0.05, 0.045, 0.01, plasticMaterial(white: 0.04)),
            (0.30, 0.06, 0.04, 0.07, 0.01, plasticMaterial(white: 0.05)),
        ]
        for part in raised {
            let box = SCNBox(width: part.width, height: part.height, length: part.depth, chamferRadius: 0.003)
            box.materials = [part.material]
            root.addChildNode(mount(SCNNode(geometry: box), along: part.along, y: part.y, thickness: part.depth))
        }

        // The optical sensor's LEDs: dark dies until a measurement lights them.
        let green = UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)
        let placements: [(along: Float, y: Float, color: UIColor)] = [
            (0.1, 0.075, green), (0.1, -0.075, green), (-0.1, -0.08, UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)),
        ]
        var leds: [SCNNode] = []
        for placement in placements {
            let die = SCNBox(width: 0.024, height: 0.018, length: 0.006, chamferRadius: 0.002)
            die.materials = [ledMaterial(placement.color)]
            let node = SCNNode(geometry: die)
            root.addChildNode(mount(node, along: placement.along, y: placement.y, thickness: 0.006))
            leds.append(node)
        }

        let glow = SCNNode()
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 0.3, green: 1, blue: 0.45, alpha: 1)
        light.intensity = 0
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = 0.9
        glow.light = light
        glow.position = SCNVector3(0, 0, Float(-(innerRadius - 0.12)))
        root.addChildNode(glow)

        let spinner = SCNNode()
        spinner.addChildNode(root)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, leds: leds, glow: glow)
    }

    // MARK: Scene

    /// One scene plus the nodes that animate. Held by `RingSceneView`.
    final class Live {
        static let idleLED: CGFloat = 0.15

        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let leds: [SCNNode]
        private let glow: SCNNode

        init(spin: Bool, tilt: Float = RingModel.defaultTilt, cameraDistance: Float = 4.2,
             spinSeconds: Double = 34) {
            let parts = RingModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            leds = parts.leds
            glow = parts.glow

            scene.background.contents = UIColor.clear
            scene.lightingEnvironment.contents = RingModel.environment
            scene.lightingEnvironment.intensity = 1.6
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(tilt, 0, 0.32)
            if spin {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)),
                                  forKey: "spin")
            }

            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 700, .white, SCNVector3(-0.6, 0.5, 0)),
                (.directional, 450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1), SCNVector3(-0.2, -2.3, 0)),
                (.directional, 350, .white, SCNVector3(0.9, 2.8, 0)),
                (.ambient, 120, .white, SCNVector3Zero),
            ]
            for (type, intensity, color, euler) in lights {
                let light = SCNLight()
                light.type = type
                light.intensity = intensity
                light.color = color
                let node = SCNNode()
                node.light = light
                node.eulerAngles = euler
                scene.rootNode.addChildNode(node)
            }

            let lens = SCNCamera()
            lens.fieldOfView = 30
            camera.camera = lens
            camera.position = SCNVector3(0, 0, cameraDistance)
            scene.rootNode.addChildNode(camera)
        }

        /// Whether a measurement wants the LEDs pulsing, so a find flash can hand back to it.
        private var measuring = false

        func playEntrance() {
            pivot.scale = SCNVector3(0.6, 0.6, 0.6)
            pivot.opacity = 0
            let grow = SCNAction.scale(to: 1, duration: 0.55)
            grow.timingMode = .easeOut
            pivot.runAction(.group([grow, .fadeIn(duration: 0.35)]))
        }

        /// The LEDs breathe and cast a green glow while a measurement runs.
        func setPulsing(_ on: Bool) {
            measuring = on
            pulse(on)
        }

        private func pulse(_ on: Bool) {
            leds.forEach { $0.removeAction(forKey: "pulse") }
            glow.removeAction(forKey: "pulse")
            guard on else {
                leds.forEach { $0.geometry?.firstMaterial?.emission.intensity = Self.idleLED }
                glow.light?.intensity = 0
                return
            }
            let period = 1.0
            let idle = Self.idleLED
            let pulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.geometry?.firstMaterial?.emission.intensity = idle + (2 - idle) * CGFloat(phase)
            }
            leds.forEach { $0.runAction(.repeatForever(pulse), forKey: "pulse") }
            let glowPulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.light?.intensity = CGFloat(40 * phase)
            }
            glow.runAction(.repeatForever(glowPulse), forKey: "pulse")
        }

        /// "Find ring": a quick hop and a burst of LED light.
        func flash() {
            let hop = SCNAction.sequence([.scale(to: 1.08, duration: 0.12), .scale(to: 1.0, duration: 0.18)])
            pivot.runAction(.repeat(hop, count: 3), forKey: "hop")
            pulse(true)
            // Back to whatever a running measurement wants, not simply off.
            pivot.runAction(.sequence([.wait(duration: 2.0), .run { [weak self] _ in
                guard let self else { return }
                self.pulse(self.measuring)
            }]), forKey: "flash")
        }
    }
}
