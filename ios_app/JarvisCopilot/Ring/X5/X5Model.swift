import SceneKit
import UIKit

/// A procedural X5 touch ring, after the real one (photos IMG_9046/9047): a wide, flat band of
/// glossy black with squared edges, a white touch target on top — a circle drawn as four arcs
/// broken on the diagonals — and inside, mirror-polished steel with a dark resin window over the
/// sensor and the laser marks (QR, "SIZE 10", CE, serial).
///
/// The ring's axis is Y, as in `RingModel`. Units: the outer radius is 1.
enum X5Model {
    // A size-10 X5 is 19.8 mm inside with a ~2.2 mm wall (24.2 mm across) and 8 mm wide, so
    // the band is a third of the diameter — visibly wider and flatter than the R12.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.818
    static let width: CGFloat = 0.661
    static let defaultTilt: Float = 0.95
    /// The edges are nearly square: a small round-over, much tighter than the R12's.
    private static let fillet: CGFloat = 0.032

    // The touch target, in millimetres on the outside of the band (measured: its circle is about
    // a quarter of the ring's diameter).
    static let circumference: Double = 2 * .pi * 12.1
    static let bandWidth: Double = 8.0
    static let touchTargetRadius: Double = 2.95
    static let touchTargetLine: Double = 0.34
    /// Where the target sits round the band: facing the camera before the ring turns.
    static let touchTargetU: Double = 0.25

    // MARK: Profile

    /// The black shell: top face, round-over, outer face, round-over, bottom face.
    private static var shellProfile: [Lathe.Point] {
        let f = fillet, h = width / 2, ri = innerRadius, ro = outerRadius
        var points = Lathe.line(from: (ri + f, h), to: (ro - f, h), normal: (0, 1), steps: 3)
        points += Lathe.arc(r: ro - f, y: h - f, radius: f, from: .pi / 2, to: 0, steps: 8).dropFirst()
        points += Lathe.line(from: (ro, h - f), to: (ro, -h + f), normal: (1, 0), steps: 10).dropFirst()
        points += Lathe.arc(r: ro - f, y: -h + f, radius: f, from: 0, to: -.pi / 2, steps: 8).dropFirst()
        points += Lathe.line(from: (ro - f, -h), to: (ri + f, -h), normal: (0, -1), steps: 3).dropFirst()
        return points
    }

    /// The bright inner edges — the steel liner showing at each rim.
    private static var lips: [[Lathe.Point]] {
        let f = fillet, h = width / 2, ri = innerRadius
        return [Lathe.arc(r: ri + f, y: h - f, radius: f, from: .pi, to: .pi / 2, steps: 6),
                Lathe.arc(r: ri + f, y: -h + f, radius: f, from: -.pi / 2, to: -.pi, steps: 6)]
    }

    private static var innerBand: [Lathe.Point] {
        let h = width / 2 - fillet
        return Lathe.line(from: (innerRadius, -h), to: (innerRadius, h), normal: (-1, 0), steps: 6)
    }

    // MARK: Textures

    /// The outside of the band: black, with the touch target's four white arcs. `glow` is the
    /// target alone, for the emission that lights it on a gesture.
    static let outerFace: (color: UIImage, metalness: UIImage, glow: UIImage) = {
        (drawOuter(.color), drawOuter(.metalness), drawOuter(.glow))
    }()

    private enum Pass { case color, metalness, glow }

    private static func drawOuter(_ pass: Pass) -> UIImage {
        // Square pixels: 2048 round the band, its 8 mm across in proportion.
        let size = CGSize(width: 2048, height: (2048 * bandWidth / circumference).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let base: UIColor
            switch pass {
            case .color: base = UIColor(white: 0.035, alpha: 1)
            case .metalness: base = UIColor(white: 0.72, alpha: 1)
            case .glow: base = .black
            }
            base.setFill()
            g.fill(CGRect(origin: .zero, size: size))
            let mm = size.width / CGFloat(circumference)
            let centre = CGPoint(x: CGFloat(touchTargetU) * size.width, y: size.height / 2)
            let radius = CGFloat(touchTargetRadius) * mm
            let ink: UIColor
            switch pass {
            case .color: ink = UIColor(white: 0.93, alpha: 1)
            case .metalness: ink = .black
            case .glow: ink = .white
            }
            g.setStrokeColor(ink.cgColor)
            g.setLineWidth(CGFloat(touchTargetLine) * mm)
            g.setLineCap(.round)
            // Four arcs, each broken off ~8° short of the diagonals.
            let gap = CGFloat(8) * .pi / 180
            for quarter in 0..<4 {
                let start = CGFloat(quarter) * .pi / 2 + .pi / 4 + gap
                let end = start + .pi / 2 - 2 * gap
                g.addArc(center: centre, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                g.strokePath()
            }
        }
    }

    /// The inside: polished steel; the resin window over the sensor round the back (u 0.75, where
    /// the LEDs are mounted); the laser marks to one side of it.
    static let innerFace: (color: UIImage, metalness: UIImage) = (drawInner(metalness: false), drawInner(metalness: true))

    private static func drawInner(metalness: Bool) -> UIImage {
        let size = CGSize(width: 2048, height: 210)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            (metalness ? UIColor(white: 1, alpha: 1) : UIColor(white: 0.42, alpha: 1)).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            // Resin window: dark, not metal, with the board's parts faintly through it.
            let window = CGRect(x: 0.685 * size.width, y: 0.14 * size.height, width: 0.13 * size.width, height: 0.72 * size.height)
            (metalness ? UIColor.black : UIColor(white: 0.06, alpha: 1)).setFill()
            g.addPath(UIBezierPath(roundedRect: window, cornerRadius: 22).cgPath)
            g.fillPath()
            if !metalness {
                var rng = SystemRandomNumberGenerator()
                for _ in 0..<26 {
                    let w = CGFloat.random(in: 6...22, using: &rng), h = CGFloat.random(in: 5...16, using: &rng)
                    let x = CGFloat.random(in: window.minX + 10...(window.maxX - 10 - w), using: &rng)
                    let y = CGFloat.random(in: window.minY + 8...(window.maxY - 8 - h), using: &rng)
                    UIColor(white: CGFloat.random(in: 0.14...0.32, using: &rng), alpha: 1).setFill()
                    g.fill(CGRect(x: x, y: y, width: w, height: h))
                }
            }
            // Laser marks, etched pale and matte.
            let markInk = metalness ? UIColor(white: 0.15, alpha: 1) : UIColor(white: 0.95, alpha: 1)
            func text(_ string: String, _ point: CGPoint, size pt: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: pt, weight: .semibold), .foregroundColor: markInk, .kern: 1.5,
                ]
                (string as NSString).draw(at: point, withAttributes: attributes)
            }
            let marks = 0.44 * size.width
            text("CE", CGPoint(x: marks, y: 0.32 * size.height), size: 44)
            text("SIZE 10", CGPoint(x: marks + 80, y: 0.22 * size.height), size: 24)
            text("0716023", CGPoint(x: marks + 80, y: 0.56 * size.height), size: 24)
            // A QR code's worth of squares.
            let qr = CGRect(x: marks + 230, y: 0.18 * size.height, width: 0.64 * size.height, height: 0.64 * size.height)
            let cells = 15
            let cell = qr.width / CGFloat(cells)
            markInk.setFill()
            var seed: UInt64 = 0x5EED_0716
            for row in 0..<cells {
                for col in 0..<cells {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let finder = (row < 4 && col < 4) || (row < 4 && col > cells - 5) || (row > cells - 5 && col < 4)
                    let on = finder ? (row % 3 == 0 || col % 3 == 0 || (row % 4 == 1 && col % 4 == 1))
                                    : (seed >> 33) & 1 == 1
                    if on { g.fill(CGRect(x: qr.minX + CGFloat(col) * cell, y: qr.minY + CGFloat(row) * cell, width: cell, height: cell)) }
                }
            }
        }
    }

    // MARK: Materials

    private static func shellMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = outerFace.color
        m.diffuse.mipFilter = .linear
        m.metalness.contents = outerFace.metalness
        m.metalness.mipFilter = .linear
        m.roughness.contents = 0.12
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.03
        m.emission.contents = outerFace.glow
        m.emission.intensity = 0
        return m
    }

    private static func steelMaterial(roughness: CGFloat = 0.05) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = innerFace.color
        m.diffuse.mipFilter = .linear
        m.metalness.contents = innerFace.metalness
        m.metalness.mipFilter = .linear
        m.roughness.contents = roughness
        return m
    }

    private static func lipMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.6, alpha: 1)
        m.metalness.contents = 1.0
        m.roughness.contents = 0.06
        return m
    }

    private static func ledMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        m.emission.contents = color
        m.emission.intensity = WearableStage.idleLED
        return m
    }

    private static func domeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        return m
    }

    /// Sets `node` on the inner face `along` the way round (0…1, the lathe's u) and `y` across,
    /// facing the axis.
    private static func mountInside(_ node: SCNNode, u: CGFloat, y: Float, depth: CGFloat) -> SCNNode {
        let a = 2 * CGFloat.pi * u
        let r = innerRadius - depth / 2
        node.position = SCNVector3(Float(r * cos(a)), y, Float(r * sin(a)))
        node.eulerAngles.y = Float(atan2(-cos(a), -sin(a)))
        return node
    }

    // MARK: Assembly

    struct Parts {
        let pivot: SCNNode
        let spinner: SCNNode
        let leds: [SCNNode]
        let glow: SCNNode
        let shell: SCNMaterial
    }

    static func makeNode() -> Parts {
        let root = SCNNode()
        let shellGeometry = Lathe.geometry(shellProfile, segments: 128)
        let shell = shellMaterial()
        shellGeometry.materials = [shell]
        root.addChildNode(SCNNode(geometry: shellGeometry))

        for lip in lips {
            let geometry = Lathe.geometry(lip, segments: 128)
            geometry.materials = [lipMaterial()]
            root.addChildNode(SCNNode(geometry: geometry))
        }

        let inner = Lathe.geometry(innerBand, segments: 128)
        inner.materials = [steelMaterial()]
        root.addChildNode(SCNNode(geometry: inner))

        // Two raised sensor lenses in the window, and the optical sensor's LEDs between them.
        for y: Float in [0.09, -0.09] {
            let dome = SCNSphere(radius: 0.032)
            dome.segmentCount = 24
            dome.materials = [domeMaterial()]
            let node = SCNNode(geometry: dome)
            node.scale = SCNVector3(1, 1, 0.35)
            root.addChildNode(mountInside(node, u: 0.722, y: y, depth: 0.012))
        }
        let green = UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)
        var leds: [SCNNode] = []
        for (u, y, color) in [(0.75, Float(0.06), green), (0.75, -0.06, green),
                              (0.778, 0.0, UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))] {
            let die = SCNBox(width: 0.026, height: 0.02, length: 0.006, chamferRadius: 0.002)
            die.materials = [ledMaterial(color)]
            let node = SCNNode(geometry: die)
            root.addChildNode(mountInside(node, u: CGFloat(u), y: y, depth: 0.006))
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
        return Parts(pivot: pivot, spinner: spinner, leds: leds, glow: glow, shell: shell)
    }

    // MARK: Scene

    /// The ring on its stage. Held by `X5SceneView`.
    final class Live: WearableStage {
        private let shell: SCNMaterial

        init(spin: Bool, tilt: Float = X5Model.defaultTilt, cameraDistance: Float = 4.2,
             spinSeconds: Double = 34, spinAngle: Float = 0) {
            let parts = X5Model.makeNode()
            shell = parts.shell
            super.init(pivot: parts.pivot, spinner: parts.spinner, leds: parts.leds, glow: parts.glow, spin: spin,
                       tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds, spinAngle: spinAngle)
        }

        /// A gesture: the touch target lights up and fades.
        func touch() {
            let material = shell
            pivot.removeAction(forKey: "touch")
            pivot.runAction(.customAction(duration: 0.7) { _, elapsed in
                let t = Double(elapsed) / 0.7
                material.emission.intensity = CGFloat(t < 0.2 ? t / 0.2 * 1.6 : (1 - t) / 0.8 * 1.6)
            }, forKey: "touch")
        }
    }
}
