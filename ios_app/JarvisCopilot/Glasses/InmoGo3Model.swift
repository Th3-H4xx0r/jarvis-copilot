import SceneKit
import UIKit

/// A procedural INMO GO3, after the product photographs and the diagram in its manual: one
/// molded wayfarer front in matte charcoal — a deep brow, a solid face round each lens with a
/// thin bright bevel on its edges, and a round lens element in each flared top corner, the camera
/// on the right — and satin black arms of flattened rounded section that run straight back past
/// a thin red band and a small label, then bend down hard into the ear end (the magnetic
/// battery), capped in grey. The clear lenses carry a faint waveguide window where the green
/// micro-LED display lights up.
///
/// Scene units are decimetres, so the numbers read as the real sizes: a 140 mm front, 50 × 38 mm
/// lenses, 150 mm arms. The front faces +Z, the arms run back along -Z, and "right" is the
/// wearer's — the -X side.
enum InmoGo3Model {
    /// Leans the top toward the camera so the lenses and the near arm both read.
    static let defaultTilt: Float = 0.34

    private static let lensSize = CGSize(width: 0.50, height: 0.38)
    /// Lens centres sit this far either side of the bridge — a 20 mm bridge.
    private static let lensX: CGFloat = 0.35
    /// The frame's face round the sides and bottom of each lens: 4.5 mm.
    private static let rim: CGFloat = 0.045
    /// How much deeper the brow is than the rest of the rim: 8.5 mm over the lens in all.
    private static let brow: CGFloat = 0.04
    private static let frameDepth: CGFloat = 0.055
    private static let frameTop = lensSize.height / 2 + rim + brow
    private static let halfWidth: CGFloat = 0.70
    /// Half the arm's height at the hinge; it is this many times taller than wide throughout.
    private static let armHalf: CGFloat = 0.05
    private static let armAspect: CGFloat = 1.4
    private static let hingeHeight = frameTop - 0.06
    /// Height of the round lens elements in the top corners.
    private static let cornerHeight = Float(frameTop - 0.05)
    /// The display window in each lens, and where its centre sits above the lens centre.
    private static let displaySize = CGSize(width: 0.25, height: 0.15)
    private static let displayLift: CGFloat = 0.02

    // MARK: Outlines

    /// A closed polygon with each corner rounded to its own radius.
    private static func roundedPolygon(_ corners: [(CGPoint, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        let first = corners[0].0, last = corners[corners.count - 1].0
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for (index, corner) in corners.enumerated() {
            path.addArc(tangent1End: corner.0, tangent2End: corners[(index + 1) % corners.count].0,
                        radius: corner.1)
        }
        path.closeSubpath()
        return path
    }

    /// The right-hand lens (temple side at +x) about its own centre, grown by `g` all round and
    /// the top by `raise` more: a wayfarer — a straight top along the brow, the outer side sloping
    /// in going down, well-rounded lower corners, and the nose side curving away round the pads.
    private static func lensOutline(grow g: CGFloat, raise: CGFloat = 0) -> CGPath {
        let w = lensSize.width / 2 + g, h = lensSize.height / 2 + g
        return roundedPolygon([
            (CGPoint(x: -w, y: h + raise), 0.045 + g),
            (CGPoint(x: w, y: h + raise), 0.05 + g),
            (CGPoint(x: w - 0.07, y: -h), 0.15 + g),
            (CGPoint(x: -w + 0.05, y: -h), 0.17 + g),
        ])
    }

    /// Moves a right-hand outline to one side of the bridge, mirroring it for the left.
    private static func placed(_ path: CGPath, side: CGFloat) -> CGPath {
        let placement = CGAffineTransform(translationX: side * lensX, y: 0).scaledBy(x: side, y: 1)
        let out = CGMutablePath()
        out.addPath(path, transform: placement)
        return out
    }

    /// The whole front as one molded outline — each lens wrapped in a solid rim under a straight,
    /// deeper brow, the bridge, and the end pieces flowing out of the brow at the top corners —
    /// with the two lens openings cut out of it.
    private static var frontOutline: CGPath {
        // The bridge block, wide enough to bury the rims' rounded inner corners so the brow runs
        // straight across, with the nose arch cut up into its underside.
        var solid = CGPath(roundedRect: CGRect(x: -0.16, y: 0.12, width: 0.32, height: frameTop - 0.12),
                           cornerWidth: 0.03, cornerHeight: 0.03, transform: nil)
        let arch = CGPath(ellipseIn: CGRect(x: -0.075, y: -0.07, width: 0.15, height: 0.24), transform: nil)
        // The end piece: flush with the brow, out past the rim round the top corner, then
        // tapering back into it a third of the way down the lens.
        let endPiece = roundedPolygon([
            (CGPoint(x: 0, y: frameTop), 0), (CGPoint(x: halfWidth - lensX, y: frameTop), 0.03),
            (CGPoint(x: halfWidth - lensX - 0.015, y: 0.14), 0.06), (CGPoint(x: 0.25, y: 0), 0.02),
        ])
        for side: CGFloat in [-1, 1] {
            solid = solid.union(placed(lensOutline(grow: rim, raise: brow), side: side))
            solid = solid.union(placed(endPiece, side: side))
        }
        for side: CGFloat in [-1, 1] {
            solid = solid.subtracting(placed(lensOutline(grow: 0), side: side))
        }
        return solid.subtracting(arch)
    }

    /// An outline extruded along Z with a flat bevel — the front's polished edge.
    private static func extrude(_ path: CGPath, depth: CGFloat, chamfer: CGFloat) -> SCNShape {
        let bezier = UIBezierPath(cgPath: path)
        bezier.usesEvenOddFillRule = true
        // The default flatness is in points; the model is a unit or so across.
        bezier.flatness = 0.002
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        return shape
    }

    // MARK: Arms

    private struct Station {
        var point: CGPoint
        var angle: CGFloat
        var half: CGFloat
    }

    private static func smooth(_ t: CGFloat) -> CGFloat {
        let u = min(1, max(0, t))
        return u * u * (3 - 2 * u)
    }

    /// The arm's centre line in its own plane — x back from the hinge, y up — every 1 mm: dead
    /// straight and tapering a little from the hinge, a short hard bend over the ear, then the
    /// ear end hanging down at 60°, swelling a touch where the battery sits. `half` is half its
    /// height.
    private static let stations: [Station] = {
        var out: [Station] = []
        var point = CGPoint(x: -0.03, y: hingeHeight)
        var s: CGFloat = -0.03
        while s <= 1.5 {
            let angle = -1.05 * smooth((s - 0.96) / 0.16)
            let half = armHalf - 0.006 * smooth(s / 0.96) + 0.003 * smooth((s - 0.96) / 0.2)
            out.append(Station(point: point, angle: angle, half: half))
            point.x += cos(angle) * 0.01
            point.y += sin(angle) * 0.01
            s += 0.01
        }
        return out
    }()

    /// The station `s` along the arm.
    private static func station(at s: CGFloat) -> Int { min(stations.count - 1, Int(((s + 0.03) / 0.01).rounded())) }

    /// The arm as a tube swept along the stations in `range` (x back → -Z): a flattened
    /// rounded-rectangle section — the superellipse |x/a|³ + |y/b|³ = 1 — `armAspect` times
    /// taller than wide, grown by `grow` all round, with a rounded end when it is the tip. An
    /// extruded side profile could not do this: SCNShape's chamfer tears near half the section.
    private static func tube(_ range: ClosedRange<Int>, roundTip: Bool, grow: CGFloat = 0) -> SCNGeometry {
        let segments = 32
        func power(_ v: CGFloat, _ p: CGFloat) -> CGFloat { copysign(pow(abs(v), p), v) }
        // Each ring: its station, and how far round the rounded end it sits (0 = on the arm).
        var rings = stations[range].map { ($0, CGFloat(0)) }
        if roundTip, let end = stations[range].last {
            rings += (1...6).map { (end, CGFloat($0) / 6 * .pi / 2) }
        }
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for (station, phi) in rings {
            let along = CGPoint(x: cos(station.angle), y: sin(station.angle))
            let up = CGPoint(x: -along.y, y: along.x)
            let half = station.half + grow, width = station.half / armAspect + grow
            let a = width * cos(phi), b = half * cos(phi), push = half * sin(phi)
            for j in 0...segments {
                let theta = 2 * CGFloat.pi * CGFloat(j) / CGFloat(segments)
                let lift = b * power(sin(theta), 2 / 3)
                positions.append(SCNVector3(Float(a * power(cos(theta), 2 / 3)),
                                            Float(station.point.y + along.y * push + up.y * lift),
                                            Float(-(station.point.x + along.x * push + up.x * lift))))
                let across = power(cos(theta), 4 / 3) / width, rise = power(sin(theta), 4 / 3) / half
                let length = max(1e-6, hypot(across, rise))
                let (nx, nu) = (across / length * cos(phi), rise / length * cos(phi))
                normals.append(SCNVector3(Float(nx), Float(up.y * nu + along.y * sin(phi)),
                                          Float(-(up.x * nu + along.x * sin(phi)))))
            }
        }
        var indices: [Int32] = []
        let row = segments + 1
        for i in 0..<(rings.count - 1) {
            for j in 0..<segments {
                let a = Int32(i * row + j), b = a + 1, c = a + Int32(row), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: Textures

    /// The display's green: the GO3's single-colour micro-LED.
    private static let displayGreen = UIColor(red: 0.24, green: 1, blue: 0.48, alpha: 1)

    /// What the display shows, drawn to be read from in front of the glasses: a faint wash over
    /// the whole window, "JARVIS", a rule, and a status line, each with a soft glow. Clear
    /// everywhere else, and added rather than alpha-blended: an opaque black printed a dark box
    /// on a lit background, and the premultiplied glow dimmed the lens it sat on.
    private static let hud: UIImage = {
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            displayGreen.withAlphaComponent(0.06).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6), cornerRadius: 36).fill()
            g.setShadow(offset: .zero, blur: 16, color: displayGreen.cgColor)
            let title = NSAttributedString(string: "JARVIS", attributes: [
                .font: UIFont.systemFont(ofSize: 150, weight: .heavy),
                .foregroundColor: displayGreen, .kern: 10,
            ])
            let bounds = title.size()
            title.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 44))
            displayGreen.setFill()
            g.fill(CGRect(x: 64, y: 244, width: size.width - 128, height: 8))
            g.fillEllipse(in: CGRect(x: 74, y: 292, width: 48, height: 48))
            for bar in 0..<3 {
                g.fill(CGRect(x: 160 + CGFloat(bar) * 128, y: 304, width: 104, height: 24))
            }
        }
    }()

    // MARK: Materials

    private static func pbr(_ color: UIColor, roughness: CGFloat, metalness: CGFloat = 0,
                            clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = 0.3
        return m
    }

    /// Bead-blasted charcoal for the front — a shade lighter than the arms — and the polished
    /// bevel that catches the light round its edges.
    private static func frontFinish() -> SCNMaterial { pbr(UIColor(white: 0.2, alpha: 1), roughness: 0.62, metalness: 0.35) }
    private static func bevelFinish() -> SCNMaterial { pbr(UIColor(white: 0.62, alpha: 1), roughness: 0.22, metalness: 0.85) }
    /// Satin black for the arms.
    private static func armFinish() -> SCNMaterial { pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.38, clearCoat: 0.2) }
    private static func silver() -> SCNMaterial { pbr(UIColor(white: 0.78, alpha: 1), roughness: 0.2, metalness: 1) }

    private static func glassMaterial() -> SCNMaterial {
        let m = pbr(UIColor(red: 0.62, green: 0.70, blue: 0.76, alpha: 0.06), roughness: 0.03)
        m.transparencyMode = .dualLayer
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }

    /// Unlit, so it reads the same whichever way the glasses face.
    private static func overlayMaterial(_ contents: Any, blend: SCNBlendMode, transparency: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        m.diffuse.mipFilter = .linear
        m.transparency = transparency
        m.blendMode = blend
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    // MARK: Assembly

    struct Parts {
        /// Tilt and scale.
        let pivot: SCNNode
        /// Turntable, about the glasses' own centre.
        let spinner: SCNNode
        /// The green display in each lens.
        let displays: [SCNNode]
    }

    /// One material, or an SCNShape's five: front, back, sides, front chamfer, back chamfer.
    private static func node(_ geometry: SCNGeometry, _ materials: SCNMaterial..., at position: SCNVector3,
                             euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.materials = materials
        let node = SCNNode(geometry: geometry)
        node.position = position
        node.eulerAngles = euler
        return node
    }

    /// A round lens element set in a top corner: a silver ring round dark glass, with a glint.
    private static func cornerLens(at x: Float) -> SCNNode {
        let element = SCNNode()
        let front = Float(frameDepth / 2)
        let facing = SCNVector3(Float.pi / 2, 0, 0)  // Y-axis primitives turned to face +Z
        let parts: [(CGFloat, CGFloat, SCNMaterial)] = [
            (0.034, 0.008, silver()),
            (0.024, 0.01, pbr(UIColor(red: 0.01, green: 0.012, blue: 0.02, alpha: 1), roughness: 0.05, clearCoat: 1)),
            (0.009, 0.011, pbr(UIColor(red: 0.10, green: 0.14, blue: 0.30, alpha: 1), roughness: 0.1, metalness: 0.6)),
        ]
        for (radius, height, material) in parts {
            element.addChildNode(node(SCNCylinder(radius: radius, height: height), material,
                                      at: SCNVector3(x, cornerHeight, front + Float(height) / 2 - 0.003), euler: facing))
        }
        return element
    }

    static func makeNode() -> Parts {
        let root = SCNNode()
        let back = -Float(frameDepth / 2)
        let front = frontFinish()

        let bevel = bevelFinish()
        root.addChildNode(node(extrude(frontOutline, depth: frameDepth, chamfer: 0.006),
                               front, front, front, bevel, bevel, at: SCNVector3Zero))

        var displays: [SCNNode] = []
        for side: Float in [-1, 1] {
            let x = side * Float(lensX)
            // The lens runs into a groove in the rim, so it is cut a little larger than the opening.
            let lens = node(extrude(placed(lensOutline(grow: 0.012), side: CGFloat(side)), depth: 0.016, chamfer: 0),
                            glassMaterial(), at: SCNVector3Zero)
            lens.renderingOrder = 10
            root.addChildNode(lens)
            // The waveguide's display window: barely there until it lights.
            let pane = SCNPlane(width: displaySize.width, height: displaySize.height)
            pane.cornerRadius = 0.018
            let window = node(pane, overlayMaterial(UIColor.white, blend: .alpha, transparency: 0.02),
                              at: SCNVector3(x, Float(displayLift), 0.0085))
            window.renderingOrder = 11
            root.addChildNode(window)
            let display = node(SCNPlane(width: displaySize.width, height: displaySize.height),
                               overlayMaterial(hud, blend: .add),
                               at: SCNVector3(x, Float(displayLift), 0.009))
            display.renderingOrder = 12
            display.opacity = 0
            root.addChildNode(display)
            displays.append(display)

            root.addChildNode(cornerLens(at: side * Float(halfWidth - 0.052)))

            // The arm, hinged behind the end piece, and the grey cap on the end of its battery.
            let armX = side * Float(halfWidth - armHalf / armAspect)
            let cap = station(at: 1.44), tip = stations.count - 1
            root.addChildNode(node(tube(0...cap, roundTip: false), armFinish(), at: SCNVector3(armX, 0, back)))
            root.addChildNode(node(tube(cap...tip, roundTip: true), pbr(UIColor(white: 0.55, alpha: 1), roughness: 0.45),
                                   at: SCNVector3(armX, 0, back)))

            // The red band round the arm just behind the hinge, and the label plate after it.
            root.addChildNode(node(tube(station(at: 0.06)...station(at: 0.08), roundTip: false, grow: 0.003),
                                   pbr(UIColor(red: 0.88, green: 0.10, blue: 0.08, alpha: 1), roughness: 0.3, clearCoat: 0.6),
                                   at: SCNVector3(armX, 0, back)))
            let labelSide = Float(stations[station(at: 0.13)].half / armAspect) + 0.001
            root.addChildNode(node(SCNBox(width: 0.004, height: 0.016, length: 0.07, chamferRadius: 0.002), silver(),
                                   at: SCNVector3(armX + side * labelSide, Float(hingeHeight), back - 0.13)))

            // A dark nose pad on a short wire arm behind each rim.
            let wireFrom = SCNVector3(side * 0.08, 0.06, back), padAt = SCNVector3(side * 0.095, -0.02, back - 0.06)
            let wire = node(SCNCylinder(radius: 0.005, height: 0.1), silver(),
                            at: SCNVector3((wireFrom.x + padAt.x) / 2, (wireFrom.y + padAt.y) / 2, (wireFrom.z + padAt.z) / 2))
            wire.simdLook(at: SIMD3(padAt), up: SIMD3(0, 0, 1), localFront: SIMD3(0, 1, 0))
            root.addChildNode(wire)
            let pad = node(SCNSphere(radius: 0.034), pbr(UIColor(white: 0.07, alpha: 1), roughness: 0.5),
                           at: padAt, euler: SCNVector3(0.2, -side * 0.6, 0))
            pad.scale = SCNVector3(0.9, 1.35, 0.35)
            root.addChildNode(pad)
        }

        // The Power and GO keys: two slots in the outside of the right arm, near the front.
        for u: CGFloat in [0.26, 0.34] {
            let outside = Float(halfWidth - armHalf / armAspect + stations[station(at: u)].half / armAspect)
            root.addChildNode(node(SCNBox(width: 0.006, height: 0.012, length: 0.05, chamferRadius: 0.003),
                                   pbr(UIColor(white: 0.01, alpha: 1), roughness: 0.9),
                                   at: SCNVector3(-outside + 0.002, Float(hingeHeight), back - Float(u))))
        }

        // Turn about the middle of the whole pair, not the front.
        let tip = stations[stations.count - 1]
        let rear = -frameDepth / 2 - tip.point.x - tip.half
        let low = tip.point.y - tip.half
        root.position = SCNVector3(0, Float(-(frameTop + low) / 2), Float(-(frameDepth / 2 + rear) / 2))

        let spinner = SCNNode()
        spinner.addChildNode(root)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, displays: displays)
    }

    // MARK: Scene

    /// One scene plus the nodes that animate. Held by `GlassesSceneView`.
    final class Live {
        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let displays: [SCNNode]

        init(spin: Bool, tilt: Float = InmoGo3Model.defaultTilt, cameraDistance: Float = 4.2,
             spinSeconds: Double = 40, spinAngle: Float = 0.62) {
            let parts = InmoGo3Model.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            displays = parts.displays

            scene.background.contents = UIColor.clear
            // The ring's studio: the same soft reflections across every wearable.
            scene.lightingEnvironment.contents = RingModel.environment
            scene.lightingEnvironment.intensity = 1.4
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(tilt, 0, 0)
            // A three-quarter pose: the lenses turned to the right, the near arm running back.
            spinner.eulerAngles.y = spinAngle
            if spin {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)),
                                  forKey: "spin")
            }

            // The ring's rig, except the third light: there it shines up into the band, here it
            // comes down from behind so the black rims and arms get a lit top edge rather than
            // bright undersides.
            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 700, .white, SCNVector3(-0.6, 0.5, 0)),
                (.directional, 450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1), SCNVector3(-0.2, -2.3, 0)),
                (.directional, 350, .white, SCNVector3(-0.9, 2.8, 0)),
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

        func playEntrance() {
            pivot.scale = SCNVector3(0.6, 0.6, 0.6)
            pivot.opacity = 0
            let grow = SCNAction.scale(to: 1, duration: 0.55)
            grow.timingMode = .easeOut
            pivot.runAction(.group([grow, .fadeIn(duration: 0.35)]))
        }

        /// The display comes up green while the glasses are connected, and fades out when not.
        func setLit(_ on: Bool) {
            let fade = SCNAction.fadeOpacity(to: on ? 1 : 0, duration: 0.45)
            fade.timingMode = .easeOut
            displays.forEach { $0.runAction(fade, forKey: "lit") }
        }
    }
}
