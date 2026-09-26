import SceneKit
import UIKit

/// A procedural INMO GO3, after the product photographs and the diagram in its manual: a classic
/// rectangular wayfarer front in matte gunmetal — an even rim round each wide lens, a slightly
/// deeper brow that dips at a chunky bridge, a gentle wrap, and a round pod on each outer top
/// corner (the camera on the right, a sensor on the left) — and satin black arms of flattened
/// oval section that run straight back past a thin red band and a small label, then bend down
/// into a long drop (the magnetic battery) with a light grey tip. The lenses are clear glass;
/// the green micro-LED display in them is invisible until it lights.
///
/// Scene units are decimetres, so the numbers read as the real sizes: a 139 mm front, 52 × 36 mm
/// lenses, 155 mm arms. The front faces +Z, the arms run back along -Z, and "right" is the
/// wearer's — the -X side.
enum InmoGo3Model {
    /// Leans the top toward the camera so the lenses and the near arm both read.
    static let defaultTilt: Float = 0.34

    // Measured off INMO's straight-on product photo (a 755 px front, lenses 274 × 177 px) and
    // scaled to its 52 mm lens: the rims are thin, the frame only 40 mm tall.
    private static let lensSize = CGSize(width: 0.52, height: 0.34)
    /// Lens centres sit this far either side of the middle — a 17 mm bridge at the top.
    private static let lensX: CGFloat = 0.345
    /// The frame round each lens (3.8 mm; the bottom is three-quarters of that). No deeper brow.
    private static let rim: CGFloat = 0.038
    private static let brow: CGFloat = 0
    private static let frameDepth: CGFloat = 0.045
    /// The frame's top at its outer ends.
    private static let frameTop = lensSize.height / 2 + rim + brow
    /// Each half of the front turns back this far from the bridge.
    private static let wrap: CGFloat = 0.06
    /// The round pods on the outer top corners, about the lens centre: just under the top line,
    /// standing about 6 mm proud of the side.
    private static let podRadius: CGFloat = 0.057
    private static let podCentre = CGPoint(x: 0.305, y: frameTop - podRadius - 0.008)
    private static let halfWidth = lensX + podCentre.x + podRadius
    /// Half the arm's height at the hinge (8 mm tall); it is this many times taller than wide.
    private static let armHalf: CGFloat = 0.04
    private static let armAspect: CGFloat = 1.5
    /// The arms leave the frame level with the pods.
    private static let hingeHeight = podCentre.y
    /// The display, across the upper part of each lens.
    private static let displaySize = CGSize(width: 0.38, height: 0.165)
    private static let displayLift: CGFloat = 0.055

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

    /// The +X lens (temple side at +x) about its own centre, grown by `g` (three-quarters of it at
    /// the bottom, where the photo's rim is thinner) and the top by `raise` more: the wayfarer —
    /// a near-straight top rising a touch toward the temple, both sides sloping in toward the
    /// bottom (the temple side ~12°, the nose side ~15°), a gently curved bottom.
    private static func lensOutline(grow g: CGFloat, raise: CGFloat = 0) -> CGPath {
        let w = lensSize.width / 2 + g, top = lensSize.height / 2 + g + raise
        let bottom = -lensSize.height / 2 - 0.75 * g
        return roundedPolygon([
            (CGPoint(x: -w, y: top - 0.009), 0.045 + g),
            (CGPoint(x: w, y: top), 0.04 + g),
            (CGPoint(x: w - 0.07, y: bottom + 0.005), 0.12 + g),
            (CGPoint(x: 0.01, y: bottom - 0.007), 0.9 + g),
            (CGPoint(x: -w + 0.1, y: bottom + 0.005), 0.1 + g),
        ])
    }

    /// Moves a +X outline to one side of the bridge, mirroring it for the other.
    private static func placed(_ path: CGPath, side: CGFloat) -> CGPath {
        let placement = CGAffineTransform(translationX: side * lensX, y: 0).scaledBy(x: side, y: 1)
        let out = CGMutablePath()
        out.addPath(path, transform: placement)
        return out
    }

    /// The whole front as one molded outline: an even rim round each lens under a slightly
    /// deeper brow, a chunky bridge whose top sags a little below the brows and whose underside
    /// is the nose arch, and the corner pods — with the two lens openings cut out of it.
    private static var frontOutline: CGPath {
        let bridge = CGMutablePath()
        // The top sags ~2 mm at the middle; the nose arch is 13 mm wide and peaks ~5 mm above
        // the lens centres.
        bridge.move(to: CGPoint(x: -0.12, y: frameTop - 0.012))
        bridge.addQuadCurve(to: CGPoint(x: 0.12, y: frameTop - 0.012), control: CGPoint(x: 0, y: frameTop - 0.03))
        bridge.addLine(to: CGPoint(x: 0.12, y: -0.02))
        bridge.addLine(to: CGPoint(x: 0.065, y: -0.02))
        bridge.addQuadCurve(to: CGPoint(x: -0.065, y: -0.02), control: CGPoint(x: 0, y: 0.115))
        bridge.addLine(to: CGPoint(x: -0.12, y: -0.02))
        bridge.closeSubpath()
        let pod = CGPath(ellipseIn: CGRect(x: podCentre.x - podRadius, y: podCentre.y - podRadius,
                                           width: 2 * podRadius, height: 2 * podRadius), transform: nil)
        var solid: CGPath = bridge
        for side: CGFloat in [-1, 1] {
            solid = solid.union(placed(lensOutline(grow: rim, raise: brow), side: side))
            solid = solid.union(placed(pod, side: side))
        }
        for side: CGFloat in [-1, 1] {
            solid = solid.subtracting(placed(lensOutline(grow: 0), side: side))
        }
        return solid
    }

    /// An outline extruded along Z with a small bevel on its edges.
    private static func extrude(_ path: CGPath, depth: CGFloat, chamfer: CGFloat) -> SCNShape {
        let bezier = UIBezierPath(cgPath: path)
        bezier.usesEvenOddFillRule = true
        // The default flatness is in points; the model is a unit or so across.
        bezier.flatness = 0.002
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.chamferRadius = chamfer
        return shape
    }

    /// Bends the front into its wrap as it is drawn — SCNShape only builds its mesh then, so there
    /// are no vertices to move up front: each side turns back about the bridge's front edge,
    /// eased in across the bridge so the frame curves there instead of creasing. Everything else
    /// on a side rides in a node turned the same way (see `makeNode`).
    private static let wrapModifier = """
        float x = _geometry.position.x;
        float a = \(wrap) * smoothstep(0.0, 0.1, abs(x)) * sign(x);
        float c = cos(a), s = sin(a), z = _geometry.position.z - \(frameDepth / 2);
        _geometry.position.x = x * c + z * s;
        _geometry.position.z = \(frameDepth / 2) - x * s + z * c;
        float3 n = _geometry.normal;
        _geometry.normal = float3(n.x * c + n.z * s, n.y, -n.x * s + n.z * c);
        """

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
    /// straight and tapering a little from the hinge, a short bend over the ear, then a long drop
    /// at about 57°, swelling a touch where the battery sits. `half` is half its height.
    private static let stations: [Station] = {
        var out: [Station] = []
        var point = CGPoint(x: -0.03, y: hingeHeight)
        var s: CGFloat = -0.03
        while s <= 1.55 {
            let angle = -1.0 * smooth((s - 0.9) / 0.16)
            let half = armHalf - 0.006 * smooth(s / 0.9) + 0.003 * smooth((s - 0.9) / 0.2)
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

    /// What the display shows, drawn to be read from in front of the glasses: a few lines of small
    /// green text under a rule, each with a soft glow, on nothing — it is added to the lens.
    private static let hud: UIImage = {
        let size = CGSize(width: 1024, height: 444)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            g.setShadow(offset: .zero, blur: 10, color: displayGreen.cgColor)
            func line(_ text: String, at y: CGFloat, size: CGFloat, weight: UIFont.Weight = .semibold) {
                NSAttributedString(string: text, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: displayGreen,
                ]).draw(at: CGPoint(x: 36, y: y))
            }
            line("JARVIS  ·  10:41", at: 12, size: 70, weight: .bold)
            displayGreen.setFill()
            g.fill(CGRect(x: 36, y: 112, width: 952, height: 5))
            line("Stand-up with Maya in 12 min", at: 138, size: 54)
            line("Reply: \"On my way\"  >", at: 220, size: 54)
            line("72°F  ·  14 min walk", at: 302, size: 54)
            g.fill(CGRect(x: 36, y: 400, width: 560, height: 12))
        }
    }()

    /// The clear lens, cut to its outline: a faint blue over the glass and soft studio
    /// reflections — a sheen down from the top and a diagonal streak — so it reads as glass on
    /// the app's near-black background and still lets the nose pads show through.
    private static let glass: UIImage = {
        let size = CGSize(width: 560, height: 420)  // 0.56 × 0.42 about the lens centre, 1 px per 0.1 mm
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            g.translateBy(x: size.width / 2, y: size.height / 2)
            g.scaleBy(x: 1000, y: -1000)
            g.addPath(lensOutline(grow: 0.006))
            g.clip()
            UIColor(red: 0.6, green: 0.78, blue: 1, alpha: 0.035).setFill()
            g.fill(CGRect(x: -0.3, y: -0.25, width: 0.6, height: 0.5))
            func sheen(from: CGPoint, to: CGPoint, _ stops: [(CGFloat, CGFloat)]) {
                let colors = stops.map { UIColor(red: 0.9, green: 0.95, blue: 1, alpha: $0.1).cgColor } as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                                locations: stops.map(\.0)) else { return }
                g.drawLinearGradient(gradient, start: from, end: to, options: [])
            }
            sheen(from: CGPoint(x: 0, y: 0.19), to: CGPoint(x: 0, y: 0.02), [(0, 0.05), (1, 0)])
            sheen(from: CGPoint(x: -0.2, y: 0.2), to: CGPoint(x: 0.2, y: -0.2),
                  [(0.3, 0), (0.4, 0.09), (0.48, 0), (0.54, 0), (0.58, 0.05), (0.62, 0)])
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

    /// Matte gunmetal for the front — a shade lighter than the arms — with only a soft lift on
    /// its bevelled edges.
    private static func frontFinish() -> SCNMaterial {
        pbr(UIColor(red: 0.27, green: 0.275, blue: 0.29, alpha: 1), roughness: 0.58, metalness: 0.45)
    }
    private static func edgeFinish() -> SCNMaterial {
        pbr(UIColor(red: 0.36, green: 0.365, blue: 0.38, alpha: 1), roughness: 0.4, metalness: 0.55)
    }
    /// Satin black for the arms.
    private static func armFinish() -> SCNMaterial { pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.38, clearCoat: 0.2) }
    private static func silver() -> SCNMaterial { pbr(UIColor(white: 0.78, alpha: 1), roughness: 0.2, metalness: 1) }

    /// Unlit, so it reads the same whichever way the glasses face.
    private static func overlayMaterial(_ image: UIImage, blend: SCNBlendMode) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.diffuse.mipFilter = .linear
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

    /// A corner pod: a round boss standing a millimetre proud of the front, holding the camera —
    /// dark glass in a silver ring, with a glint — or the sensor, a dark disc in a dark ring.
    private static func pod(at x: Float, camera: Bool) -> SCNNode {
        let pod = SCNNode()
        let front = frontFinish(), face = Float(frameDepth / 2) + 0.01
        let circle = CGPath(ellipseIn: CGRect(x: -podRadius, y: -podRadius, width: 2 * podRadius, height: 2 * podRadius),
                            transform: nil)
        pod.addChildNode(node(extrude(circle, depth: 0.02, chamfer: 0.004), front, front, front, edgeFinish(), front,
                              at: SCNVector3(x, Float(podCentre.y), face - 0.01)))
        let glass = pbr(UIColor(red: 0.01, green: 0.012, blue: 0.02, alpha: 1), roughness: 0.05, clearCoat: 1)
        let parts: [(CGFloat, SCNMaterial)] = camera
            ? [(0.03, silver()), (0.021, glass),
               (0.008, pbr(UIColor(red: 0.1, green: 0.14, blue: 0.3, alpha: 1), roughness: 0.1, metalness: 0.6))]
            : [(0.027, pbr(UIColor(white: 0.1, alpha: 1), roughness: 0.3, metalness: 0.5)), (0.019, glass)]
        for (index, (radius, material)) in parts.enumerated() {
            pod.addChildNode(node(SCNCylinder(radius: radius, height: 0.004), material,
                                  at: SCNVector3(x, Float(podCentre.y), face + 0.001 * Float(index)),
                                  euler: SCNVector3(Float.pi / 2, 0, 0)))  // Y-axis primitives turned to face +Z
        }
        return pod
    }

    static func makeNode() -> Parts {
        let root = SCNNode()
        let front = Float(frameDepth / 2), back = -front
        let face = frontFinish(), edge = edgeFinish()

        let frame = extrude(frontOutline, depth: frameDepth, chamfer: 0.005)
        frame.shaderModifiers = [.geometry: wrapModifier]
        root.addChildNode(node(frame, face, face, face, edge, edge, at: SCNVector3Zero))

        var displays: [SCNNode] = []
        for side: Float in [-1, 1] {
            // Everything on this side turns back with its half of the front.
            let half = SCNNode()
            half.position.z = front
            half.eulerAngles.y = side * Float(wrap)
            let body = SCNNode()
            body.position.z = -front
            half.addChildNode(body)
            root.addChildNode(half)

            let x = side * Float(lensX)
            let lens = node(SCNPlane(width: 0.56, height: 0.42), overlayMaterial(glass, blend: .alpha), at: SCNVector3(x, 0, 0))
            lens.scale.x = side  // the outline is drawn for the +X lens
            lens.renderingOrder = 10
            body.addChildNode(lens)
            let display = node(SCNPlane(width: displaySize.width, height: displaySize.height),
                               overlayMaterial(hud, blend: .add), at: SCNVector3(x, Float(displayLift), 0.001))
            display.renderingOrder = 12
            display.opacity = 0
            body.addChildNode(display)
            displays.append(display)

            body.addChildNode(pod(at: side * Float(lensX + podCentre.x), camera: side < 0))

            // The arm, hinged behind the pod, and the grey cap on the end of its battery.
            let armX = side * Float(halfWidth - armHalf / armAspect)
            let cap = station(at: 1.49), tip = stations.count - 1
            body.addChildNode(node(tube(0...cap, roundTip: false), armFinish(), at: SCNVector3(armX, 0, back)))
            body.addChildNode(node(tube(cap...tip, roundTip: true), pbr(UIColor(white: 0.62, alpha: 1), roughness: 0.45),
                                   at: SCNVector3(armX, 0, back)))

            // The red band round the arm just behind the hinge, and the label plate after it.
            body.addChildNode(node(tube(station(at: 0.06)...station(at: 0.08), roundTip: false, grow: 0.003),
                                   pbr(UIColor(red: 0.88, green: 0.10, blue: 0.08, alpha: 1), roughness: 0.3, clearCoat: 0.6),
                                   at: SCNVector3(armX, 0, back)))
            let labelSide = Float(stations[station(at: 0.13)].half / armAspect) + 0.001
            body.addChildNode(node(SCNBox(width: 0.004, height: 0.016, length: 0.07, chamferRadius: 0.002), silver(),
                                   at: SCNVector3(armX + side * labelSide, Float(hingeHeight), back - 0.13)))

            // The Power and GO keys: two slots in the outside of the right arm, near the front.
            for u: CGFloat in [0.26, 0.34] where side < 0 {
                let outside = Float(stations[station(at: u)].half / armAspect)
                body.addChildNode(node(SCNBox(width: 0.006, height: 0.012, length: 0.05, chamferRadius: 0.003),
                                       pbr(UIColor(white: 0.01, alpha: 1), roughness: 0.9),
                                       at: SCNVector3(armX - outside + 0.002, Float(hingeHeight), back - Float(u))))
            }

            // A dark nose pad on a short wire arm behind each rim.
            // Just inside each lens's nose edge, where the photo shows them through the glass.
            let wireFrom = SCNVector3(side * 0.09, 0.03, back), padAt = SCNVector3(side * 0.118, -0.045, back - 0.06)
            let wire = node(SCNCylinder(radius: 0.005, height: 0.1), silver(),
                            at: SCNVector3((wireFrom.x + padAt.x) / 2, (wireFrom.y + padAt.y) / 2, (wireFrom.z + padAt.z) / 2))
            wire.simdLook(at: SIMD3(padAt), up: SIMD3(0, 0, 1), localFront: SIMD3(0, 1, 0))
            body.addChildNode(wire)
            let pad = node(SCNSphere(radius: 0.034), pbr(UIColor(white: 0.07, alpha: 1), roughness: 0.5),
                           at: padAt, euler: SCNVector3(0.2, -side * 0.6, 0))
            pad.scale = SCNVector3(0.9, 1.35, 0.35)
            body.addChildNode(pad)
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
            // comes down from behind so the frame and arms get a lit top edge rather than bright
            // undersides.
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
