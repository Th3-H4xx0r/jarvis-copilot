import SceneKit
import SwiftUI
import UIKit

/// The Affver A4 built from primitives, after the product shot: a glossy black body with a brushed
/// silver front panel, the lens in a square bezel at the right end, the GPS mount block on top,
/// the SD slot on the left end and the 3.59" screen on the back. "Lit" = connected: the screen
/// glows and the red REC light comes on.
enum DashcamModel {
    // Body proportions (scene units; the body is 2.0 long).
    static let length: CGFloat = 2.0
    static let height: CGFloat = 0.64
    static let depth: CGFloat = 0.62
    static let defaultTilt: Float = 0.2

    private static func pbr(_ color: UIColor, roughness: CGFloat, metalness: CGFloat = 0,
                            clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = 0.25
        return m
    }

    /// Glossy piano black, like the shell in the photo.
    private static func shell() -> SCNMaterial { pbr(UIColor(white: 0.035, alpha: 1), roughness: 0.28, clearCoat: 0.6) }
    /// Matte dark grey for the mount's adhesive plate.
    private static func plate() -> SCNMaterial { pbr(UIColor(white: 0.16, alpha: 1), roughness: 0.6, metalness: 0.2) }
    /// The brushed aluminium front panel: fine horizontal streaks over a cool grey.
    private static func brushed() -> SCNMaterial {
        // Not fully metallic: a pure metal mirrors the dark studio and reads charcoal, not aluminium.
        let m = pbr(UIColor(red: 0.9, green: 0.92, blue: 0.95, alpha: 1), roughness: 0.28, metalness: 0.3)
        m.diffuse.contents = brushedTexture
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        return m
    }

    static let brushedTexture: UIImage = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var rng = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: 256, by: 1) {
                let shade = 0.84 + Double.random(in: 0...0.12, using: &rng)
                UIColor(white: shade, alpha: 0.35).setFill()
                ctx.fill(CGRect(x: 0, y: CGFloat(y), width: 256, height: 1))
            }
        }
    }()

    /// The coated lens face: transparent outside the circle; cyan rim → violet → blue → dark pupil.
    static let lensImage: UIImage = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = CGPoint(x: 128, y: 128)
            let stops: [(CGFloat, UIColor)] = [
                (1.00, UIColor(red: 0.30, green: 0.78, blue: 0.92, alpha: 1)),
                (0.90, UIColor(red: 0.42, green: 0.28, blue: 0.86, alpha: 1)),
                (0.66, UIColor(red: 0.20, green: 0.30, blue: 0.82, alpha: 1)),
                (0.42, UIColor(red: 0.08, green: 0.10, blue: 0.32, alpha: 1)),
                (0.24, UIColor(white: 0.02, alpha: 1)),
            ]
            let colors = stops.reversed().map { $0.1.cgColor } as CFArray
            let locations = stops.reversed().map { $0.0 }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)!
            ctx.cgContext.addEllipse(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            ctx.cgContext.clip()
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 128, options: [])
        }
    }()

    /// What the back screen shows while connected: the road ahead in blues, a REC badge.
    static let screenImage: UIImage = {
        let size = CGSize(width: 512, height: 150)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.30, green: 0.52, blue: 0.86, alpha: 1).cgColor,
                          UIColor(red: 0.06, green: 0.10, blue: 0.24, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.85, alpha: 0.35).setFill()   // horizon and road edges
            ctx.fill(CGRect(x: 0, y: 70, width: size.width, height: 2))
            let road = UIBezierPath()
            road.move(to: CGPoint(x: 200, y: 150)); road.addLine(to: CGPoint(x: 250, y: 72))
            road.addLine(to: CGPoint(x: 262, y: 72)); road.addLine(to: CGPoint(x: 320, y: 150)); road.close()
            UIColor(white: 0.05, alpha: 0.55).setFill(); road.fill()
            UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 18, y: 14, width: 14, height: 14))
            let text: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .bold),
                                                       .foregroundColor: UIColor.white]
            ("REC" as NSString).draw(at: CGPoint(x: 38, y: 11), withAttributes: text)
            ("38 mph" as NSString).draw(at: CGPoint(x: 430, y: 118), withAttributes: text)
        }
    }()

    private static func node(_ geometry: SCNGeometry, _ material: SCNMaterial, at p: SCNVector3,
                             euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.position = p
        n.eulerAngles = euler
        return n
    }

    struct Parts {
        let pivot: SCNNode
        let spinner: SCNNode
        let lit: [SCNNode]
    }

    static func makeNode() -> Parts {
        let spinner = SCNNode()
        let front = Float(depth / 2)

        // Body: a long rounded block.
        spinner.addChildNode(node(SCNBox(width: length, height: height, length: depth, chamferRadius: 0.2), shell(),
                                  at: SCNVector3Zero))
        // Brushed silver front panel over the left two-thirds.
        let panel = SCNBox(width: 1.08, height: height - 0.14, length: 0.03, chamferRadius: 0.07)
        spinner.addChildNode(node(panel, brushed(), at: SCNVector3(-0.25, 0, front - 0.005)))
        // Speaker grille: a short dark slot on the panel.
        spinner.addChildNode(node(SCNBox(width: 0.22, height: 0.035, length: 0.012, chamferRadius: 0.012),
                                  pbr(UIColor(white: 0.08, alpha: 1), roughness: 0.5), at: SCNVector3(0.12, -0.02, front + 0.014)))
        // Lens bezel at the right end: a square black boss, a touch proud of the body.
        let bezel = SCNBox(width: 0.62, height: height - 0.04, length: 0.08, chamferRadius: 0.12)
        spinner.addChildNode(node(bezel, shell(), at: SCNVector3(0.66, 0, front + 0.005)))
        // The lens: dark metal barrel, a thin bright ring, then the coated glass — cyan rim, violet and
        // blue coatings, a dark pupil — under a clear coat, with two glints.
        let lensZ = front + 0.05
        let barrels: [(CGFloat, CGFloat, SCNMaterial)] = [
            (0.245, 0.05, pbr(UIColor(white: 0.14, alpha: 1), roughness: 0.22, metalness: 0.9)),
            (0.215, 0.07, pbr(UIColor(white: 0.03, alpha: 1), roughness: 0.35)),
            (0.198, 0.075, pbr(UIColor(white: 0.85, alpha: 1), roughness: 0.15, metalness: 1)),
        ]
        for (r, h, m) in barrels {
            spinner.addChildNode(node(SCNCylinder(radius: r, height: h), m, at: SCNVector3(0.66, 0, lensZ),
                                      euler: SCNVector3(Float.pi / 2, 0, 0)))
        }
        let glass = pbr(.white, roughness: 0.05, metalness: 0.2, clearCoat: 1)
        glass.diffuse.contents = lensImage
        glass.emission.contents = lensImage
        glass.emission.intensity = 0.35
        glass.transparencyMode = .aOne
        spinner.addChildNode(node(SCNPlane(width: 0.38, height: 0.38), glass, at: SCNVector3(0.66, 0, lensZ + 0.04)))
        let glint = SCNMaterial()
        glint.lightingModel = .constant
        glint.diffuse.contents = UIColor(white: 1, alpha: 0.9)
        spinner.addChildNode(node(SCNSphere(radius: 0.02), glint, at: SCNVector3(0.6, 0.075, lensZ + 0.05)))
        spinner.addChildNode(node(SCNSphere(radius: 0.009), glint, at: SCNVector3(0.715, -0.06, lensZ + 0.05)))
        // Mount block on top, and its lighter adhesive plate.
        let top = Float(height / 2)
        spinner.addChildNode(node(SCNBox(width: 0.96, height: 0.34, length: 0.5, chamferRadius: 0.09), shell(),
                                  at: SCNVector3(0.1, top + 0.06, -0.02)))
        spinner.addChildNode(node(SCNBox(width: 0.9, height: 0.06, length: 0.58, chamferRadius: 0.03), plate(),
                                  at: SCNVector3(0.1, top + 0.25, -0.03), euler: SCNVector3(-0.06, 0, 0)))
        // SD slot on the left end.
        spinner.addChildNode(node(SCNBox(width: 0.012, height: 0.05, length: 0.28, chamferRadius: 0.005),
                                  pbr(UIColor(white: 0.01, alpha: 1), roughness: 0.6),
                                  at: SCNVector3(-Float(length / 2) - 0.002, 0.08, 0)))

        // The back screen: dark glass, with the live picture fading in while connected.
        let back = -Float(depth / 2)
        spinner.addChildNode(node(SCNBox(width: 1.6, height: height - 0.12, length: 0.012, chamferRadius: 0.04),
                                  pbr(UIColor(white: 0.02, alpha: 1), roughness: 0.08, clearCoat: 1),
                                  at: SCNVector3(0, 0, back - 0.002)))
        let picture = SCNMaterial()
        picture.lightingModel = .constant
        picture.diffuse.contents = screenImage
        let screen = node(SCNPlane(width: 1.5, height: height - 0.2), picture, at: SCNVector3(0, 0, back - 0.01),
                          euler: SCNVector3(0, Float.pi, 0))
        screen.opacity = 0
        spinner.addChildNode(screen)
        // REC light on the bezel, by the lens.
        let rec = SCNMaterial()
        rec.lightingModel = .constant
        rec.diffuse.contents = UIColor(red: 1, green: 0.18, blue: 0.16, alpha: 1)
        let led = node(SCNSphere(radius: 0.018), rec, at: SCNVector3(0.42, 0.22, front + 0.05))
        led.opacity = 0
        spinner.addChildNode(led)

        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, lit: [screen, led])
    }

    /// One scene plus the nodes that animate. Held by `DashcamSceneView`.
    final class Live {
        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let lit: [SCNNode]

        init(spin: Bool, tilt: Float = DashcamModel.defaultTilt, cameraDistance: Float = 4.6,
             spinSeconds: Double = 40, spinAngle: Float = -0.45) {
            let parts = DashcamModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            lit = parts.lit
            scene.background.contents = UIColor.clear
            scene.lightingEnvironment.contents = RingModel.environment   // the wearables' shared studio
            scene.lightingEnvironment.intensity = 1.4
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(tilt, 0, 0)
            // Three-quarter pose: lens towards the viewer, the mount on top in view.
            spinner.eulerAngles.y = spinAngle
            if spin {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)), forKey: "spin")
            }
            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 750, .white, SCNVector3(-0.6, 0.5, 0)),
                (.directional, 450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1), SCNVector3(-0.2, -2.3, 0)),
                (.directional, 380, .white, SCNVector3(-0.9, 2.8, 0)),
                (.ambient, 140, .white, SCNVector3Zero),
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
            lens.fieldOfView = 30
            camera.camera = lens
            camera.position = SCNVector3(0, 0, cameraDistance)
            scene.rootNode.addChildNode(camera)
        }

        func setLit(_ on: Bool) {
            let fade = SCNAction.fadeOpacity(to: on ? 1 : 0, duration: 0.45)
            fade.timingMode = .easeOut
            lit.forEach { $0.runAction(fade, forKey: "lit") }
        }
    }
}

/// The dashcam rendered live, like the glasses on their card.
struct DashcamSceneView: View {
    var spin = true
    var lit = false
    var tilt: Float = DashcamModel.defaultTilt
    var cameraDistance: Float = 4.6
    var spinSeconds: Double = 40
    var animatesAnywhere = false

    @State private var live: DashcamModel.Live?
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var animating: Bool {
        spin && scenePhase == .active
            && (animatesAnywhere || (router.map { $0.selectedTab == .devices } ?? true))
    }

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: animating)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard live == nil else { return }
            let scene = DashcamModel.Live(spin: spin, tilt: tilt, cameraDistance: cameraDistance, spinSeconds: spinSeconds)
            if lit { scene.setLit(true) }
            live = scene
        }
        .onChange(of: lit) { _, on in live?.setLit(on) }
    }
}
