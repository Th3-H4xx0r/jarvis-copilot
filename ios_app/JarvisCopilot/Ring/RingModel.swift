import SceneKit
import UIKit

/// A procedural Colmi R12, after QRing's product render: a glossy black shell, a clear resin
/// inner band over the circuit board, and the sensor window with its green and red LEDs.
///
/// The ring's axis is Y. The profile is a rounded rectangle in (radius, height) lathed around
/// that axis; the inner face is split off so the resin and the board behind it can differ.
enum RingModel {
    // A real R12 is ~20 mm across, ~7.5 mm wide, with a ~2.5 mm wall.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.78
    static let width: CGFloat = 0.72
    /// Leans the ring toward the camera so the inside — board, window, LEDs — shows.
    static let defaultTilt: Float = 0.95
    private static let fillet: CGFloat = 0.09

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

    /// Everything except the inner face, traced clockwise: top-inner edge → top → outer
    /// face → bottom → bottom-inner edge.
    private static var shellProfile: [ProfilePoint] {
        let f = fillet, h = width / 2, ri = innerRadius, ro = outerRadius
        var points = arc(r: ri + f, y: h - f, radius: f, from: .pi, to: .pi / 2, steps: 8)
        points += line(from: (ri + f, h), to: (ro - f, h), normal: (0, 1), steps: 4).dropFirst()
        points += arc(r: ro - f, y: h - f, radius: f, from: .pi / 2, to: 0, steps: 10).dropFirst()
        points += line(from: (ro, h - f), to: (ro, -h + f), normal: (1, 0), steps: 8).dropFirst()
        points += arc(r: ro - f, y: -h + f, radius: f, from: 0, to: -.pi / 2, steps: 10).dropFirst()
        points += line(from: (ro - f, -h), to: (ri + f, -h), normal: (0, -1), steps: 4).dropFirst()
        points += arc(r: ri + f, y: -h + f, radius: f, from: -.pi / 2, to: -.pi, steps: 8).dropFirst()
        return points
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

    /// The board behind the resin: traces, chips, gold pads and the battery strip.
    static let circuitTexture: UIImage = {
        let size = CGSize(width: 1024, height: 192)
        return UIGraphicsImageRenderer(size: size).image { context in
            let g = context.cgContext
            UIColor(red: 0.035, green: 0.05, blue: 0.045, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            var seed: UInt32 = 0x9E37_79B9
            func random() -> CGFloat {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return CGFloat(seed >> 8) / CGFloat(1 << 24)
            }
            // Battery strip.
            UIColor(white: 0.52, alpha: 1).setFill()
            g.fill(CGRect(x: 580, y: 38, width: 380, height: 116))
            UIColor(white: 0.32, alpha: 1).setStroke()
            g.setLineWidth(3)
            g.stroke(CGRect(x: 580, y: 38, width: 380, height: 116))
            // Traces.
            UIColor(red: 0.80, green: 0.63, blue: 0.30, alpha: 0.85).setStroke()
            g.setLineWidth(2)
            for _ in 0..<80 {
                var x = random() * 560
                var y = 12 + random() * 168
                g.move(to: CGPoint(x: x, y: y))
                for _ in 0..<3 {
                    if random() > 0.5 {
                        x += (random() - 0.5) * 130
                    } else {
                        y = min(180, max(12, y + (random() - 0.5) * 90))
                    }
                    g.addLine(to: CGPoint(x: x, y: y))
                }
                g.strokePath()
            }
            // Chips.
            for _ in 0..<10 {
                let w = 30 + random() * 64, h = 24 + random() * 52
                let rect = CGRect(x: random() * (540 - w), y: 18 + random() * (156 - h), width: w, height: h)
                UIColor(white: 0.07, alpha: 1).setFill()
                g.fill(rect)
                UIColor(white: 0.30, alpha: 1).setStroke()
                g.setLineWidth(1.5)
                g.stroke(rect)
            }
            // Gold pads.
            UIColor(red: 0.86, green: 0.70, blue: 0.36, alpha: 1).setFill()
            for _ in 0..<46 {
                g.fill(CGRect(x: random() * 1010, y: 6 + random() * 176, width: 6, height: 6))
            }
        }
    }()

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
        m.diffuse.contents = UIColor(white: 0.035, alpha: 1)
        m.metalness.contents = 0.6
        m.roughness.contents = 0.18
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.04
        return m
    }

    private static func resinMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 1, alpha: 0.10)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.04
        m.transparencyMode = .dualLayer
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }

    private static func circuitMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = circuitTexture
        m.metalness.contents = 0.25
        m.roughness.contents = 0.45
        return m
    }

    private static func glassMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        m.metalness.contents = 0.1
        m.roughness.contents = 0.08
        return m
    }

    private static func metalMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.75, alpha: 1)
        m.metalness.contents = 1.0
        m.roughness.contents = 0.3
        return m
    }

    private static func ledMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = 0.5
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

    static func makeNode() -> Parts {
        let root = SCNNode()

        let shell = lathe(shellProfile)
        shell.materials = [shellMaterial()]
        root.addChildNode(SCNNode(geometry: shell))

        let board = lathe(innerBand, radiusOffset: 0.03)
        board.materials = [circuitMaterial()]
        root.addChildNode(SCNNode(geometry: board))

        let resin = lathe(innerBand)
        resin.materials = [resinMaterial()]
        let resinNode = SCNNode(geometry: resin)
        resinNode.renderingOrder = 10
        root.addChildNode(resinNode)

        // Sensor window on the inside face, pointing at the finger.
        let sensor = SCNNode()
        sensor.position = SCNVector3(0, 0, Float(-(innerRadius - 0.012)))
        let window = SCNBox(width: 0.30, height: 0.15, length: 0.03, chamferRadius: 0.014)
        window.materials = [glassMaterial()]
        sensor.addChildNode(SCNNode(geometry: window))

        var leds: [SCNNode] = []
        let placements: [(x: Float, y: Float, color: UIColor)] = [
            (-0.07, -0.01, UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)),
            (0.07, -0.01, UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)),
            (0.0, 0.035, UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)),
        ]
        for placement in placements {
            let sphere = SCNSphere(radius: 0.02)
            sphere.materials = [ledMaterial(placement.color)]
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(placement.x, placement.y, 0.02)
            sensor.addChildNode(node)
            leds.append(node)
        }

        let contact = SCNTorus(ringRadius: 0.035, pipeRadius: 0.007)
        contact.materials = [metalMaterial()]
        let contactNode = SCNNode(geometry: contact)
        contactNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        contactNode.position = SCNVector3(-0.24, 0, 0.012)
        sensor.addChildNode(contactNode)
        root.addChildNode(sensor)

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
        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let leds: [SCNNode]
        private let glow: SCNNode

        init(spin: Bool, tilt: Float = RingModel.defaultTilt, cameraDistance: Float = 4.2) {
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
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)), forKey: "spin")
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
                leds.forEach { $0.geometry?.firstMaterial?.emission.intensity = 0.5 }
                glow.light?.intensity = 0
                return
            }
            let period = 1.0
            let pulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.geometry?.firstMaterial?.emission.intensity = CGFloat(0.5 + 1.5 * phase)
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
