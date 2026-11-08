import SceneKit
import UIKit

/// Lathed geometry for the rings: a profile in (radius, height) turned around the Y axis.
enum Lathe {
    struct Point {
        var r: CGFloat
        var y: CGFloat
        var nr: CGFloat
        var ny: CGFloat
    }

    static func arc(r cr: CGFloat, y cy: CGFloat, radius: CGFloat,
                    from a0: CGFloat, to a1: CGFloat, steps: Int) -> [Point] {
        (0...steps).map { i in
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            return Point(r: cr + radius * cos(a), y: cy + radius * sin(a), nr: cos(a), ny: sin(a))
        }
    }

    static func line(from p0: (CGFloat, CGFloat), to p1: (CGFloat, CGFloat),
                     normal: (CGFloat, CGFloat), steps: Int) -> [Point] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return Point(r: p0.0 + (p1.0 - p0.0) * t, y: p0.1 + (p1.1 - p0.1) * t, nr: normal.0, ny: normal.1)
        }
    }

    /// Lathes a clockwise profile; triangles wind so the given normals face out.
    static func geometry(_ profile: [Point], segments: Int, radiusOffset: CGFloat = 0) -> SCNGeometry {
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
}

/// The studio every device's model stands in: the soft environment, the lights, the camera,
/// the slow turn and the entrance. A model hands over its pivot (posed) and spinner (turned).
class ModelStage {
    typealias Light = (type: SCNLight.LightType, intensity: CGFloat, color: UIColor, euler: SCNVector3)

    /// Key, a cool fill from below, a top light, and ambient. `rim` is where the top light comes
    /// from: the rings' shines up into the band; the glasses' comes down from behind so the frame
    /// gets a lit top edge rather than bright undersides.
    static func studio(fill: (intensity: CGFloat, color: UIColor) = (450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1)),
                       rim: SCNVector3 = SCNVector3(0.9, 2.8, 0)) -> [Light] {
        [(.directional, 700, .white, SCNVector3(-0.6, 0.5, 0)),
         (.directional, fill.intensity, fill.color, SCNVector3(-0.2, -2.3, 0)),
         (.directional, 350, .white, rim),
         (.ambient, 120, .white, SCNVector3Zero)]
    }

    let scene = SCNScene()
    let camera = SCNNode()
    let pivot: SCNNode
    let spinner: SCNNode

    /// `tilt` and `roll` lean the model; `spinAngle` poses it at a fixed point in its turn (the
    /// render harness looks at each side).
    init(pivot: SCNNode, spinner: SCNNode, spin: Bool, tilt: Float, roll: Float, cameraDistance: Float,
         spinSeconds: Double, spinAngle: Float, lights: [Light] = ModelStage.studio(), environment: CGFloat = 1.6) {
        self.pivot = pivot
        self.spinner = spinner

        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = RingModel.environment
        scene.lightingEnvironment.intensity = environment
        scene.rootNode.addChildNode(pivot)
        pivot.eulerAngles = SCNVector3(tilt, 0, roll)
        spinner.eulerAngles.y = spinAngle
        if spin {
            spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)), forKey: "spin")
        }

        for light in lights {
            let source = SCNLight()
            source.type = light.type
            source.intensity = light.intensity
            source.color = light.color
            let node = SCNNode()
            node.light = source
            node.eulerAngles = light.euler
            scene.rootNode.addChildNode(node)
        }

        let lens = SCNCamera()
        lens.fieldOfView = 30
        camera.camera = lens
        camera.position = SCNVector3(0, 0, cameraDistance)
        scene.rootNode.addChildNode(camera)
    }

    func playEntrance() {
        pivot.scale = SCNVector3(0.6, 0.6, 0.6)
        pivot.opacity = 0
        let grow = SCNAction.scale(to: 1, duration: 0.55)
        grow.timingMode = .easeOut
        pivot.runAction(.group([grow, .fadeIn(duration: 0.35)]))
    }
}

/// A wearable's stage (R12, X5, band): the studio, plus the LEDs breathing through a measurement
/// and the "find" flash. `RingSceneView` & co. hold it.
class WearableStage: ModelStage {
    static let idleLED: CGFloat = 0.15

    let leds: [SCNNode]
    let glow: SCNNode
    /// Whether a measurement wants the LEDs pulsing, so a find flash can hand back to it.
    private var measuring = false

    /// `fill` is the cool light from below.
    init(pivot: SCNNode, spinner: SCNNode, leds: [SCNNode], glow: SCNNode, spin: Bool, tilt: Float,
         roll: Float = 0.32, cameraDistance: Float, spinSeconds: Double, spinAngle: Float,
         fill: (intensity: CGFloat, color: UIColor) = (450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1))) {
        self.leds = leds
        self.glow = glow
        super.init(pivot: pivot, spinner: spinner, spin: spin, tilt: tilt, roll: roll, cameraDistance: cameraDistance,
                   spinSeconds: spinSeconds, spinAngle: spinAngle, lights: ModelStage.studio(fill: fill))
    }

    /// The LEDs breathe and cast a green glow while a measurement runs.
    func setPulsing(_ on: Bool) {
        measuring = on
        pulse(on)
    }

    /// Each step of the glow's breath (0…1), or nil once it stops: for a model's own marks.
    func pulsed(_ phase: CGFloat?) {}

    /// A gesture landed on the device (the X5 lights its touch target).
    func touch() {}

    private func pulse(_ on: Bool) {
        leds.forEach { $0.removeAction(forKey: "pulse") }
        glow.removeAction(forKey: "pulse")
        guard on else {
            leds.forEach { $0.geometry?.firstMaterial?.emission.intensity = Self.idleLED }
            glow.light?.intensity = 0
            pulsed(nil)
            return
        }
        let period = 1.0
        let idle = Self.idleLED
        let pulse = SCNAction.customAction(duration: period) { node, elapsed in
            let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
            node.geometry?.firstMaterial?.emission.intensity = idle + (2 - idle) * CGFloat(phase)
        }
        leds.forEach { $0.runAction(.repeatForever(pulse), forKey: "pulse") }
        let glowPulse = SCNAction.customAction(duration: period) { [weak self] node, elapsed in
            let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
            node.light?.intensity = CGFloat(40 * phase)
            self?.pulsed(CGFloat(phase))
        }
        glow.runAction(.repeatForever(glowPulse), forKey: "pulse")
    }

    /// "Find": a quick hop and a burst of LED light.
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
