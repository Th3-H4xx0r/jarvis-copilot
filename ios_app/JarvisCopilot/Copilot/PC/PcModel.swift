import SceneKit
import UIKit

/// Pranav's gaming PC, modelled once from his four photos (2026-11-20 chat: the blue side view, the pink
/// front-corner view, the two interior close-ups) and the real parts the PC reports (B760M-C, RTX 5070,
/// 2 × T-Force UD5-6400): a CyberPowerPC dual-chamber case with panoramic glass on the front and the
/// left side, a black plinth whose top edge carries the RGB strip (side and front), seven 120 mm ARGB
/// fans — two on the top radiator, two stacked on the rear wall, three on the floor — a hex-logo AIO
/// pump with braided tubes, red RAM, the MSI Shadow 3X lying under the board, a perforated tray
/// extension in the front half and the CyberPower PSU box in front-bottom.
///
/// Every lit thing is made of LED sockets (PcLedKey → its own material) so the model glows LED by LED
/// with the colours the PC is sending (PcEffects). Units: decimetres. +X = front, +Y = up, +Z = the
/// glass side. Origin: floor, centre.
enum PcModel {
    // Proportions measured from the photos: the rear wall is ~4 fan heights tall in the side view
    // (≈ 480 mm); three 120 mm floor fans fill ~¾ of the depth (≈ 460 mm); a dual-chamber body ≈ 290 mm.
    static let width: CGFloat = 2.9
    static let depth: CGFloat = 4.6
    static let height: CGFloat = 4.8
    /// The black plinth under the glass (the strip runs along its top edge; front I/O on its face).
    static let plinth: CGFloat = 0.45
    static let fan: CGFloat = 1.2
    static let fanThickness: CGFloat = 0.25
    /// The motherboard tray: a plane a third of the way in from the right side (dual chamber).
    static let trayZ: CGFloat = -0.55
    static let ringSockets = 16
    static let stripSockets = 30
    static let logoSockets = 12

    enum View { case hero, side, front }

    final class Live {
        let scene: SCNScene
        let camera: SCNNode
        let root: SCNNode
        let leds: [PcLedKey: SCNMaterial]
        let interiorLight: SCNLight
        let floorGlow: SCNMaterial
        private let byMaterial: [ObjectIdentifier: PcLedKey]

        init(scene: SCNScene, camera: SCNNode, root: SCNNode, leds: [PcLedKey: SCNMaterial],
             interiorLight: SCNLight, floorGlow: SCNMaterial) {
            self.scene = scene; self.camera = camera; self.root = root; self.leds = leds
            self.interiorLight = interiorLight; self.floorGlow = floorGlow
            byMaterial = Dictionary(uniqueKeysWithValues: leds.map { (ObjectIdentifier($0.value), $0.key) })
        }

        /// The LED socket a tapped node is (calibration taps the lit LED).
        func socket(of node: SCNNode) -> PcLedKey? {
            guard let m = node.geometry?.firstMaterial else { return nil }
            return byMaterial[ObjectIdentifier(m)]
        }
    }

    // MARK: Materials

    private static func pbr(_ color: UIColor, metal: CGFloat = 0.2, rough: CGFloat = 0.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    private static let frame = pbr(UIColor(white: 0.035, alpha: 1), metal: 0.7, rough: 0.35)
    private static let tray = pbr(UIColor(white: 0.06, alpha: 1), metal: 0.5, rough: 0.5)
    private static let pcb = pbr(UIColor(white: 0.05, alpha: 1), metal: 0.1, rough: 0.8)
    private static let silver = pbr(UIColor(white: 0.4, alpha: 1), metal: 0.9, rough: 0.4)
    private static let ramRed = pbr(UIColor(red: 0.62, green: 0.1, blue: 0.12, alpha: 1), metal: 0.6, rough: 0.4)
    private static let shroud = pbr(UIColor(white: 0.09, alpha: 1), metal: 0.5, rough: 0.45)
    private static let rubber = pbr(UIColor(white: 0.04, alpha: 1), metal: 0, rough: 0.9)

    private static var glass: SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.03, alpha: 0.14)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        m.blendMode = .alpha
        m.transparencyMode = .aOne
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    /// Perforated steel: a diamond-hole tile, repeated.
    private static func mesh(repeat r: CGSize) -> SCNMaterial {
        let m = pbr(.white, metal: 0.6, rough: 0.5)
        m.diffuse.contents = meshTile
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(r.width), Float(r.height), 1)
        return m
    }

    private static let meshTile: UIImage = {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.16, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.015, alpha: 1).setFill()
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 16, y: 5)); p.addLine(to: CGPoint(x: 27, y: 16))
            p.addLine(to: CGPoint(x: 16, y: 27)); p.addLine(to: CGPoint(x: 5, y: 16)); p.close()
            p.fill()
        }
    }()

    private static let glowTile: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }()

    private static func led() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = UIColor.black
        return m
    }

    // MARK: Geometry helpers

    @discardableResult
    private static func box(_ parent: SCNNode, _ name: String? = nil, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>,
                            z: ClosedRange<CGFloat>, _ material: SCNMaterial, chamfer: CGFloat = 0) -> SCNNode {
        let g = SCNBox(width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound,
                       length: z.upperBound - z.lowerBound, chamferRadius: chamfer)
        g.materials = [material]
        let n = SCNNode(geometry: g)
        n.name = name
        n.position = SCNVector3((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2,
                                (z.lowerBound + z.upperBound) / 2)
        parent.addChildNode(n)
        return n
    }

    private static func text(_ parent: SCNNode, _ string: String, size: CGFloat, at p: SCNVector3,
                             euler: SCNVector3 = SCNVector3Zero, color: UIColor, italic: Bool = false) {
        let t = SCNText(string: string, extrusionDepth: 0.005)
        t.font = italic ? UIFont.italicSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size, weight: .heavy)
        t.flatness = 0.05
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color
        t.materials = [m]
        let n = SCNNode(geometry: t)
        n.position = p
        n.eulerAngles = euler
        parent.addChildNode(n)
    }

    /// A 120 mm fan in its own plane (local XY, facing local +Z): a square frame with a round hole,
    /// a ring of lit blade sectors (the LED sockets) and a dark hub. `leds` gets one material per socket.
    private static func fanNode(_ part: PcPart, _ index: Int, leds: inout [PcLedKey: SCNMaterial]) -> SCNNode {
        let node = SCNNode()
        node.name = "fan.\(part.rawValue).\(index)"
        let half = fan / 2
        let outline = UIBezierPath(roundedRect: CGRect(x: -half, y: -half, width: fan, height: fan), cornerRadius: 0.08)
        outline.append(UIBezierPath(ovalIn: CGRect(x: -0.56, y: -0.56, width: 1.12, height: 1.12)).reversing())
        outline.usesEvenOddFillRule = true
        outline.flatness = 0.004   // SceneKit flattens curves at the path's flatness: the default turns the hole into a diamond
        let frameShape = SCNShape(path: outline, extrusionDepth: fanThickness)
        frameShape.materials = [frame]
        node.addChildNode(SCNNode(geometry: frameShape))
        let step = 2 * CGFloat.pi / CGFloat(ringSockets)
        for s in 0..<ringSockets {
            let a0 = CGFloat(s) * step - step / 2, a1 = a0 + step
            let wedge = UIBezierPath()
            wedge.addArc(withCenter: .zero, radius: 0.54, startAngle: a0, endAngle: a1, clockwise: true)
            wedge.addArc(withCenter: .zero, radius: 0.19, startAngle: a1, endAngle: a0, clockwise: false)
            wedge.close()
            wedge.flatness = 0.01
            let g = SCNShape(path: wedge, extrusionDepth: 0.03)
            let m = led()
            g.materials = [m]
            let w = SCNNode(geometry: g)
            w.position.z = Float(fanThickness / 2 - 0.02)
            node.addChildNode(w)
            leds[PcLedKey(part: part, index: index, led: s)] = m
        }
        let hub = SCNCylinder(radius: 0.18, height: 0.06)
        hub.materials = [rubber]
        let hubNode = SCNNode(geometry: hub)
        hubNode.eulerAngles.x = .pi / 2
        hubNode.position.z = Float(fanThickness / 2 - 0.01)
        node.addChildNode(hubNode)
        let ring = SCNTorus(ringRadius: 0.1, pipeRadius: 0.008)
        ring.materials = [silver]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles.x = .pi / 2
        ringNode.position.z = Float(fanThickness / 2 + 0.025)
        node.addChildNode(ringNode)
        return node
    }

    /// A braided tube through `points` (cylinders between them).
    private static func tube(_ parent: SCNNode, _ points: [SCNVector3], radius: CGFloat) {
        for (a, b) in zip(points, points.dropFirst()) {
            let d = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
            let len = CGFloat(sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
            let c = SCNCylinder(radius: radius, height: len + radius)
            c.materials = [rubber]
            let n = SCNNode(geometry: c)
            n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
            n.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
            parent.addChildNode(n)
        }
    }

    private static func bezier(_ p0: SCNVector3, _ p1: SCNVector3, _ p2: SCNVector3, _ p3: SCNVector3, steps: Int = 18) -> [SCNVector3] {
        (0...steps).map { k in
            let t = Float(k) / Float(steps), u = 1 - t
            func mix(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
                u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
            }
            return SCNVector3(mix(p0.x, p1.x, p2.x, p3.x), mix(p0.y, p1.y, p2.y, p3.y), mix(p0.z, p1.z, p2.z, p3.z))
        }
    }

    // MARK: Build

    static func build(view: View = .hero) -> Live {
        let scene = SCNScene()
        let root = SCNNode()
        root.name = "pc"
        scene.rootNode.addChildNode(root)
        var leds: [PcLedKey: SCNMaterial] = [:]
        let hx = depth / 2, hz = width / 2

        // Case shell.
        let shell = SCNNode(); shell.name = "comp.case"; root.addChildNode(shell)
        box(shell, x: -hx...hx, y: 0...plinth, z: -hz...hz, frame, chamfer: 0.02)
        box(shell, x: -hx...hx, y: (height - 0.06)...height, z: -hz...hz, glass)          // smoked top
        box(shell, x: -hx...hx, y: (height - 0.1)...(height - 0.06), z: (-hz)...(-hz + 0.08), frame)
        box(shell, x: -hx...hx, y: plinth...(height - 0.06), z: (-hz)...(-hz + 0.04), frame)  // right panel
        box(shell, x: (-hx)...(-hx + 0.05), y: plinth...(height - 0.06), z: -hz...hz, frame)   // rear wall
        box(shell, x: (hx - 0.01)...hx, y: plinth...(height - 0.06), z: -hz...hz, glass)       // front glass
        box(shell, x: -hx...hx, y: plinth...(height - 0.06), z: (hz - 0.01)...hz, glass)       // side glass
        box(shell, x: (hx - 0.03)...hx, y: plinth...height, z: (hz - 0.03)...hz, frame)        // corner seam
        box(shell, x: (-hx)...(-hx + 0.04), y: (height - 0.1)...height, z: -hz...hz, frame)

        // Front I/O on the plinth: power button, two small buttons, the Intel badge.
        let power = SCNCylinder(radius: 0.06, height: 0.02)
        let powerLit = SCNMaterial(); powerLit.lightingModel = .constant; powerLit.emission.contents = UIColor(white: 0.95, alpha: 1)
        power.materials = [powerLit]
        let powerNode = SCNNode(geometry: power)
        powerNode.eulerAngles.z = .pi / 2
        powerNode.position = SCNVector3(hx + 0.005, plinth * 0.45, 0.0)
        root.addChildNode(powerNode)
        for zOff in [-0.28, 0.28] as [CGFloat] {
            box(root, x: hx...(hx + 0.01), y: (plinth * 0.45 - 0.025)...(plinth * 0.45 + 0.025),
                z: (zOff - 0.025)...(zOff + 0.025), silver, chamfer: 0.02)
        }
        box(root, x: hx...(hx + 0.008), y: (plinth * 0.3)...(plinth * 0.62), z: (-hz + 0.2)...(-hz + 0.5),
            pbr(UIColor(red: 0.1, green: 0.25, blue: 0.6, alpha: 1)))

        // Tray, its perforated front extension, the PSU box.
        box(root, "comp.tray", x: (-hx + 0.05)...(hx - 0.02), y: plinth...(height - 0.06), z: (trayZ - 0.02)...trayZ, tray)
        box(root, "comp.tray", x: 0.6...(hx - 0.04), y: 2.55...(height - 0.12), z: trayZ...(trayZ + 0.015),
            mesh(repeat: CGSize(width: 22, height: 26)))
        let psu = SCNNode(); psu.name = "comp.psu"; root.addChildNode(psu)
        box(psu, x: 0.8...(hx - 0.04), y: 0.78...2.3, z: trayZ...(trayZ + 0.95), mesh(repeat: CGSize(width: 18, height: 19)))
        text(psu, "CYBERPOWER", size: 0.1, at: SCNVector3(0.95, 2.17, Float(trayZ + 0.96)), color: UIColor(white: 0.32, alpha: 1))

        // Motherboard (mATX, 244 mm), VRM heatsinks, I/O cover, slot covers.
        let board = SCNNode(); board.name = "comp.board"; root.addChildNode(board)
        let bx0: CGFloat = -2.15, bx1: CGFloat = 0.29, by0: CGFloat = 1.55, by1: CGFloat = 3.99
        box(board, x: bx0...bx1, y: by0...by1, z: trayZ...(trayZ + 0.03), pcb)
        box(board, x: (bx0 + 0.3)...(bx0 + 1.65), y: (by1 - 0.28)...(by1 - 0.08), z: trayZ...(trayZ + 0.22), silver, chamfer: 0.02)
        box(board, x: (bx0 + 0.04)...(bx0 + 0.3), y: (by0 + 0.95)...(by1 - 0.3), z: trayZ...(trayZ + 0.25), silver, chamfer: 0.02)
        box(board, x: (bx0 + 0.55)...(bx0 + 1.05), y: (by0 + 0.45)...(by0 + 0.6), z: trayZ...(trayZ + 0.1), silver)
        box(board, "comp.slots", x: (-hx + 0.05)...(-hx + 0.1), y: 0.55...1.75, z: trayZ...(trayZ + 0.75),
            mesh(repeat: CGSize(width: 6, height: 14)))

        // RAM: two red T-Force sticks to the right of the CPU.
        let ram = SCNNode(); ram.name = "comp.ram"; root.addChildNode(ram)
        for xr in [-0.33, -0.19] as [CGFloat] {
            box(ram, x: xr...(xr + 0.07), y: (by0 + 0.75)...(by0 + 2.08), z: trayZ...(trayZ + 0.42), ramRed, chamfer: 0.01)
        }

        // AIO pump: a square black block with a glass face and the lit hex logo (the cooler's LEDs).
        let pump = SCNNode(); pump.name = "part.cooler"; root.addChildNode(pump)
        let pc = SCNVector3(-0.95, Float(by0 + 1.45), Float(trayZ + 0.03))
        box(pump, x: (CGFloat(pc.x) - 0.36)...(CGFloat(pc.x) + 0.36), y: (CGFloat(pc.y) - 0.36)...(CGFloat(pc.y) + 0.36),
            z: CGFloat(pc.z)...(CGFloat(pc.z) + 0.34), frame, chamfer: 0.05)
        box(pump, x: (CGFloat(pc.x) - 0.3)...(CGFloat(pc.x) + 0.3), y: (CGFloat(pc.y) - 0.3)...(CGFloat(pc.y) + 0.3),
            z: (CGFloat(pc.z) + 0.34)...(CGFloat(pc.z) + 0.35), glass)
        let logoR: CGFloat = 0.2
        for k in 0..<logoSockets {
            // 12 segments round a flat-topped hexagon (2 per side).
            let side = k / 2, half = k % 2
            let a0 = CGFloat(side) * .pi / 3 + .pi / 6, a1 = a0 + .pi / 3
            let p0 = CGPoint(x: logoR * cos(a0), y: logoR * sin(a0)), p1 = CGPoint(x: logoR * cos(a1), y: logoR * sin(a1))
            let t0 = CGFloat(half) / 2, t1 = t0 + 0.5
            let q0 = CGPoint(x: p0.x + (p1.x - p0.x) * t0, y: p0.y + (p1.y - p0.y) * t0)
            let q1 = CGPoint(x: p0.x + (p1.x - p0.x) * t1, y: p0.y + (p1.y - p0.y) * t1)
            let len = hypot(q1.x - q0.x, q1.y - q0.y)
            let seg = SCNBox(width: len, height: 0.035, length: 0.02, chamferRadius: 0.005)
            let m = led(); seg.materials = [m]
            let n = SCNNode(geometry: seg)
            n.position = SCNVector3(pc.x + Float((q0.x + q1.x) / 2), pc.y + Float((q0.y + q1.y) / 2), pc.z + 0.355)
            n.eulerAngles.z = Float(atan2(q1.y - q0.y, q1.x - q0.x))
            pump.addChildNode(n)
            leds[PcLedKey(part: .cooler, index: 0, led: k)] = m
        }

        // GPU: MSI Shadow 3X lying under the board, its 120 mm side facing the glass.
        let gpu = SCNNode(); gpu.name = "comp.gpu"; root.addChildNode(gpu)
        box(gpu, x: -2.15...0.95, y: 1.0...1.5, z: trayZ...(trayZ + 1.25), shroud, chamfer: 0.04)
        box(gpu, x: -2.1...0.9, y: 0.98...1.0, z: (trayZ + 0.05)...(trayZ + 1.2), rubber)
        text(gpu, "GEFORCE RTX", size: 0.16, at: SCNVector3(-1.85, 1.18, Float(trayZ + 1.26)), color: UIColor(white: 0.62, alpha: 1))
        text(gpu, "msi", size: 0.2, at: SCNVector3(-0.6, 1.14, Float(trayZ + 1.26)), color: UIColor(white: 0.5, alpha: 1), italic: true)

        // Top radiator under the smoked top, its two fans hanging below it (lit faces down, as in the photos).
        let topPart = SCNNode(); topPart.name = "part.top"; root.addChildNode(topPart)
        box(root, "comp.radiator", x: -1.8...0.8, y: 4.45...4.7, z: -0.42...0.82, mesh(repeat: CGSize(width: 30, height: 10)))
        for (i, xc) in ([-1.1, 0.12] as [CGFloat]).enumerated() {
            let f = fanNode(.top, i, leds: &leds)
            f.eulerAngles.x = .pi / 2
            f.position = SCNVector3(Float(xc), Float(4.45 - fanThickness / 2), 0.2)
            topPart.addChildNode(f)
        }

        // Rear exhaust: two fans stacked on the rear wall, facing the front.
        let rearPart = SCNNode(); rearPart.name = "part.rear"; root.addChildNode(rearPart)
        for (i, yc) in ([3.55, 2.3] as [CGFloat]).enumerated() {
            let f = fanNode(.rear, i, leds: &leds)
            f.eulerAngles.y = .pi / 2
            f.position = SCNVector3(Float(-hx + 0.05 + fanThickness / 2), Float(yc), 0.55)
            rearPart.addChildNode(f)
        }

        // Floor intake: three fans along the glass side, facing up.
        let bottomPart = SCNNode(); bottomPart.name = "part.bottom"; root.addChildNode(bottomPart)
        for (i, xc) in ([-1.45, -0.1, 1.25] as [CGFloat]).enumerated() {
            let f = fanNode(.bottom, i, leds: &leds)
            f.eulerAngles.x = -.pi / 2
            f.position = SCNVector3(Float(xc), Float(plinth + fanThickness / 2), 0.72)
            bottomPart.addChildNode(f)
        }

        // AIO tubes: pump → radiator's front end, sagging forward past the RAM.
        let tubes = SCNNode(); tubes.name = "part.cooler.tubes"; pump.addChildNode(tubes)
        for (dy, dz) in [(-0.12, 0.25), (0.12, 0.38)] as [(Float, Float)] {
            tube(tubes, bezier(SCNVector3(pc.x + 0.36, pc.y + dy, pc.z + 0.2), SCNVector3(0.6, pc.y - 0.9 + dy, dz + 0.3),
                               SCNVector3(1.2, 3.2 + dy, dz), SCNVector3(0.75, 4.5, dz - 0.15)), radius: 0.055)
        }

        // The strip along the plinth's top edge: rear → front corner on the glass side, then across the front.
        let strip = SCNNode(); strip.name = "part.strip"; root.addChildNode(strip)
        let pathLen = depth + width
        let segLen = pathLen / CGFloat(stripSockets)
        for s in 0..<stripSockets {
            let along = (CGFloat(s) + 0.5) * segLen
            let m = led()
            let n: SCNNode
            if along < depth {
                let g = SCNBox(width: segLen * 0.98, height: 0.035, length: 0.03, chamferRadius: 0.004)
                g.materials = [m]; n = SCNNode(geometry: g)
                n.position = SCNVector3(Float(-hx + along), Float(plinth + 0.018), Float(hz - 0.012))
            } else {
                let g = SCNBox(width: 0.03, height: 0.035, length: segLen * 0.98, chamferRadius: 0.004)
                g.materials = [m]; n = SCNNode(geometry: g)
                n.position = SCNVector3(Float(hx - 0.012), Float(plinth + 0.018), Float(hz - (along - depth)))
            }
            strip.addChildNode(n)
            leds[PcLedKey(part: .strip, index: 0, led: s)] = m
        }

        // Light: dark studio key + fill, and an interior light that takes the LEDs' average colour.
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient
        ambient.light!.intensity = 90; ambient.light!.color = UIColor(white: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 520
        key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let inside = SCNNode(); inside.light = SCNLight(); inside.light!.type = .omni
        inside.light!.intensity = 0; inside.light!.attenuationStartDistance = 0.5; inside.light!.attenuationEndDistance = 4.5
        inside.position = SCNVector3(0, 2.4, 0.5)
        root.addChildNode(inside)

        // The glow the fans throw on the desk.
        let glowPlane = SCNPlane(width: 7, height: 5)
        let glowMat = SCNMaterial(); glowMat.lightingModel = .constant
        glowMat.diffuse.contents = UIColor.black; glowMat.emission.contents = glowTile
        glowMat.multiply.contents = UIColor.black; glowMat.blendMode = .add; glowMat.writesToDepthBuffer = false
        glowPlane.materials = [glowMat]
        let glowNode = SCNNode(geometry: glowPlane)
        glowNode.eulerAngles.x = -.pi / 2
        glowNode.position = SCNVector3(0.3, -0.002, 0.9)
        root.addChildNode(glowNode)

        // Camera: the front-left corner a little above, like his photos.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 30
        camera.camera!.wantsHDR = true
        camera.camera!.bloomIntensity = 0.9
        camera.camera!.bloomThreshold = 0.55
        camera.camera!.bloomBlurRadius = 6
        camera.camera!.exposureOffset = -0.15
        camera.camera!.wantsExposureAdaptation = false
        let target = SCNVector3(0, 2.35, 0)
        switch view {
        case .hero: camera.position = SCNVector3(9.2, 3.4, 11.6)
        case .side: camera.position = SCNVector3(1.2, 3.0, 15.5)
        case .front: camera.position = SCNVector3(13.5, 3.8, 6.0)
        }
        camera.look(at: target)
        scene.rootNode.addChildNode(camera)

        return Live(scene: scene, camera: camera, root: root, leds: leds, interiorLight: inside.light!, floorGlow: glowMat)
    }

    // MARK: Lookups

    static func partNode(_ part: PcPart, in scene: SCNScene) -> SCNNode? {
        scene.rootNode.childNode(withName: "part.\(part.rawValue)", recursively: true)
    }

    /// The lit part a tapped node belongs to.
    static func part(of node: SCNNode) -> PcPart? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name {
                if name.hasPrefix("fan."), let p = PcPart(rawValue: String(name.split(separator: ".")[1])) { return p }
                if name.hasPrefix("part."), let p = PcPart(rawValue: String(name.split(separator: ".")[1])) { return p }
            }
            n = cur.parent
        }
        return nil
    }

    /// The component a tapped node belongs to (gpu, ram, board, psu, case …), for its info sheet.
    static func component(of node: SCNNode) -> String? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name, name.hasPrefix("comp.") { return String(name.dropFirst(5)) }
            n = cur.parent
        }
        return nil
    }

    // MARK: LED colours

    /// Which LED of an `leds`-long ring a socket shows, given where LED 0 sits and which way they run.
    static func ringLED(socket: Int, sockets: Int, leds: Int, startDeg: Double, clockwise: Bool) -> Int {
        guard leds > 0 else { return 0 }
        let angle = Double(socket) * 360 / Double(sockets)
        let rel = PcEffects.mod(clockwise ? startDeg - angle : angle - startDeg, 360)
        return Int((rel / 360 * Double(leds)).rounded(.down)) % leds
    }

    /// Lights the sockets with each segment's colours (PcEffects.ledColours, map order). A part with
    /// no LEDs stays dark; a part sharing another's LEDs ("also") shows that part's colours.
    static func apply(colours: [[SIMD3<Float>]], map: PcLedMap, to live: Live) {
        var bySlot: [String: (PcSegment, [SIMD3<Float>])] = [:]
        for (seg, cols) in zip(map.segments, colours) {
            bySlot["\(seg.part).\(seg.index ?? 0)"] = (seg, cols)
            for extra in seg.also ?? [] where bySlot["\(extra).\(seg.index ?? 0)"] == nil {
                bySlot["\(extra).\(seg.index ?? 0)"] = (seg, cols)
            }
        }
        var total = SIMD3<Float>(0, 0, 0), lit = 0
        for (key, material) in live.leds {
            var c = SIMD3<Float>(0, 0, 0)
            if let (seg, cols) = bySlot["\(key.part.rawValue).\(key.index)"] ?? bySlot["\(key.part.rawValue).0"], !cols.isEmpty {
                let n = cols.count
                let i: Int
                switch key.part {
                case .strip:
                    let pos = Int(Double(key.led) / Double(stripSockets) * Double(n))
                    i = seg.from == "front" ? n - 1 - pos : pos
                case .cooler:
                    i = ringLED(socket: key.led, sockets: logoSockets, leds: n, startDeg: seg.ringStartDeg ?? 0,
                                clockwise: seg.clockwise ?? true)
                default:
                    i = ringLED(socket: key.led, sockets: ringSockets, leds: n, startDeg: seg.ringStartDeg ?? 0,
                                clockwise: seg.clockwise ?? true)
                }
                c = cols[max(0, min(n - 1, i))]
            }
            material.emission.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            total += c; lit += 1
        }
        let avg = lit > 0 ? total / Float(lit) : SIMD3<Float>(0, 0, 0)
        let avgColor = UIColor(red: CGFloat(avg.x), green: CGFloat(avg.y), blue: CGFloat(avg.z), alpha: 1)
        live.interiorLight.color = avgColor
        live.interiorLight.intensity = CGFloat(min(1, (avg.x + avg.y + avg.z) / 1.2)) * 620
        live.floorGlow.multiply.contents = avgColor
    }

    /// All LEDs dark (lighting off, the PC asleep, or not set up).
    static func unlit(_ live: Live) {
        apply(colours: [], map: PcLedMap(), to: live)
    }
}
