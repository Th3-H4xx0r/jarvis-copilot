import SceneKit
import UIKit

/// A procedural INMO GO3, after the product photographs: a CNC-aluminium wayfarer front in matte
/// gunmetal — rounded-rectangle lens openings with near-vertical sides, a heavier brow along the
/// top, soft rounded edges, and a keyhole bridge (the brow runs straight across over a rounded
/// arch, thickened in the middle). Each top outer corner runs into a solid end piece that turns
/// back to the hinge, with a round camera lens set flush in its front face (the camera on the
/// right, a sensor that looks the same on the left). A small red block sits at each hinge and a
/// thin red ring round the arm just behind it; the satin black arms run straight back past a
/// small INMO mark, bend down behind the ear into a stub, and the black battery stick plugs onto
/// that. The lenses are clear glass; the green micro-LED display in them is invisible until it
/// lights.
///
/// Scene units are decimetres, so the numbers read as the real sizes: a 139 mm front, 52 × 34 mm
/// lenses, 155 mm arms. The front faces +Z, the arms run back along -Z, and "right" is the
/// wearer's — the -X side.
enum InmoGo3Model {
    /// Leans the top toward the camera so the lenses and the near arm both read.
    static let defaultTilt: Float = 0.34

    // Measured off INMO's straight-on product photo (a 755 px front, lenses 274 × 177 px) and
    // scaled to its 52 mm lens.
    private static let lensSize = CGSize(width: 0.52, height: 0.34)
    /// Lens centres sit this far either side of the middle — a 17 mm bridge at the top.
    private static let lensX: CGFloat = 0.345
    /// The frame round each lens: 3.6 mm at the sides, a little less under it, a 5.5 mm brow.
    private static let rimSide: CGFloat = 0.036
    private static let rimBottom: CGFloat = 0.032
    private static let brow: CGFloat = 0.055
    /// The front is 4.8 mm deep, its edges rounded off 1.3 mm.
    private static let frameDepth: CGFloat = 0.048
    private static let edgeRound: CGFloat = 0.013
    /// The frame's top, straight across.
    private static let frameTop = lensSize.height / 2 + brow
    /// The end piece reaches this far past the lens's outer edge (139 mm across).
    private static let endReach: CGFloat = 0.095
    private static let halfWidth = lensX + lensSize.width / 2 + endReach
    /// The end piece's depth behind the front, side to side.
    private static let endWidth: CGFloat = 0.06
    /// Each half of the front turns back this far from the bridge.
    private static let wrap: CGFloat = 0.06
    /// The camera: 7 mm across — about the arm's height — tucked into the lens's rounded top
    /// outer corner, its centre 1 mm under the lens top and 3.6 mm outside it.
    private static let cameraRadius: CGFloat = 0.035
    private static let cameraCentre = CGPoint(x: lensSize.width / 2 + 0.036, y: lensSize.height / 2 - 0.01)
    /// Half the arm's height (8 mm tall); it is this many times taller than wide.
    private static let armHalf: CGFloat = 0.04
    private static let armAspect: CGFloat = 1.5
    /// The arms leave level with the cameras, their tops just under the frame's top.
    private static let hingeHeight = frameTop - 0.05
    /// Where the arm leaves the red hinge block, back from the front's centre.
    private static let armStart: CGFloat = 0.10
    /// The battery stick: 35 mm long, 10 mm deep in the arm's plane, 7 mm thick.
    private static let battery = (length: CGFloat(0.35), height: CGFloat(0.10), thickness: CGFloat(0.07))
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

    /// The +X lens opening (temple side at +x) about its own centre, grown by `g`: a rounded
    /// rectangle with a straight top, near-vertical sides that close in only 1–2 mm toward the
    /// bottom, a softly curved bottom, and bottom corners much rounder than the top ones.
    private static func lensOutline(grow g: CGFloat = 0) -> CGPath {
        let w = lensSize.width / 2, h = lensSize.height / 2
        return roundedPolygon([
            (CGPoint(x: -w - g, y: h + g), 0.10 + g),
            (CGPoint(x: w + g, y: h + g), 0.08 + g),
            (CGPoint(x: w - 0.015 + g, y: -h - g), 0.17 + g),
            (CGPoint(x: 0, y: -h - 0.014 - g), 1),
            (CGPoint(x: -w + 0.065 - g, y: -h - g), 0.17 + g),
        ])
    }

    /// The outside of the +X half of the front about that lens's centre: the rim round the lens,
    /// the brow straight along the top, and the top outer corner swelling out into the end
    /// piece's face, which holds the camera and flows back into the side rim below it.
    private static var halfOutline: CGPath {
        let w = lensSize.width / 2, h = lensSize.height / 2
        return roundedPolygon([
            (CGPoint(x: -w - rimSide, y: frameTop), 0.02),
            (CGPoint(x: w + endReach, y: frameTop), 0.055),
            (CGPoint(x: w + endReach, y: h - 0.05), 0.05),
            (CGPoint(x: w + rimSide, y: h - 0.14), 0.09),
            (CGPoint(x: w - 0.015 + rimSide, y: -h - rimBottom), 0.17 + rimBottom),
            (CGPoint(x: 0, y: -h - 0.014 - rimBottom), 1),
            (CGPoint(x: -w + 0.065 - rimSide, y: -h - rimBottom), 0.17 + rimBottom),
        ])
    }

    /// Moves a +X outline to one side of the bridge, mirroring it for the other.
    private static func placed(_ path: CGPath, side: CGFloat) -> CGPath {
        let placement = CGAffineTransform(translationX: side * lensX, y: 0).scaledBy(x: side, y: 1)
        let out = CGMutablePath()
        out.addPath(path, transform: placement)
        return out
    }

    /// The keyhole's arch peaks this high — level with the lens tops, 5.5 mm under the brow.
    private static let archTop = lensSize.height / 2

    /// The whole front as one outline: both halves, and between them the keyhole bridge — the
    /// brow straight across and under it a rounded arch over the nose — with the two lens
    /// openings cut out.
    private static var frontOutline: CGPath {
        let bridge = CGMutablePath()
        bridge.move(to: CGPoint(x: -0.16, y: frameTop))
        bridge.addLine(to: CGPoint(x: 0.16, y: frameTop))
        bridge.addLine(to: CGPoint(x: 0.16, y: -0.02))
        // The arch's legs start where the lens rim's inner edge crosses y = -0.02, so they meet
        // it flush instead of leaving a tab.
        bridge.addLine(to: CGPoint(x: 0.087, y: -0.02))
        bridge.addCurve(to: CGPoint(x: 0, y: archTop), control1: CGPoint(x: 0.072, y: archTop - 0.07),
                        control2: CGPoint(x: 0.048, y: archTop))
        bridge.addCurve(to: CGPoint(x: -0.087, y: -0.02), control1: CGPoint(x: -0.048, y: archTop),
                        control2: CGPoint(x: -0.072, y: archTop - 0.07))
        bridge.addLine(to: CGPoint(x: -0.16, y: -0.02))
        bridge.closeSubpath()
        var solid: CGPath = bridge
        for side: CGFloat in [-1, 1] {
            solid = solid.union(placed(halfOutline, side: side))
        }
        for side: CGFloat in [-1, 1] {
            solid = solid.subtracting(placed(lensOutline(), side: side))
        }
        return solid
    }

    /// The saddle: the bridge thickened in the middle, a rounded swelling from the top of the
    /// arch up into the brow.
    private static var saddleOutline: CGPath {
        roundedPolygon([
            (CGPoint(x: -0.022, y: frameTop - 0.011), 0.014),
            (CGPoint(x: 0.022, y: frameTop - 0.011), 0.014),
            // Small radii: the side corners are sharp (~33°), and a larger round overruns
            // their edges into a loop SceneKit builds no mesh for.
            (CGPoint(x: 0.06, y: archTop - 0.022), 0.012),
            (CGPoint(x: 0, y: archTop + 0.008), 0.05),
            (CGPoint(x: -0.06, y: archTop - 0.022), 0.012),
        ])
    }

    /// A rounded edge rather than a flat chamfer: a quarter round from the face to the side.
    private static let roundProfile: UIBezierPath = {
        let profile = UIBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        profile.addQuadCurve(to: CGPoint(x: 1, y: 0), controlPoint: CGPoint(x: 1, y: 1))
        profile.flatness = 0.08
        return profile
    }()

    /// An outline extruded along Z with rounded edges.
    private static func extrude(_ path: CGPath, depth: CGFloat, round: CGFloat) -> SCNShape {
        let bezier = UIBezierPath(cgPath: path)
        bezier.usesEvenOddFillRule = true
        // The default flatness is in points; the model is a unit or so across.
        bezier.flatness = 0.002
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.chamferRadius = round
        shape.chamferProfile = roundProfile
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

    /// The end piece seen from the side, `u` back from the front's centre and `y` up: full height
    /// at the front, where it is part of the frame's corner, closing down to the arm at the hinge.
    private static var endProfile: CGPath {
        roundedPolygon([
            // Its front starts under the front's rounded outer corner (radius 0.055) so no square
            // block shows past the curve.
            (CGPoint(x: 0, y: frameTop - 0.045), 0),
            (CGPoint(x: 0.07, y: frameTop - 0.003), 0.03),
            (CGPoint(x: armStart, y: hingeHeight + armHalf + 0.002), 0.012),
            (CGPoint(x: armStart, y: hingeHeight - armHalf - 0.002), 0.012),
            (CGPoint(x: 0.055, y: lensSize.height / 2 - 0.075), 0.04),
            (CGPoint(x: 0, y: lensSize.height / 2 - 0.05), 0),
        ])
    }

    // MARK: Arms

    private struct Station {
        var point: CGPoint
        var angle: CGFloat
        /// Half the height and half the width of the section.
        var half: CGFloat
        var width: CGFloat
    }

    private static func smooth(_ t: CGFloat) -> CGFloat {
        let u = min(1, max(0, t))
        return u * u * (3 - 2 * u)
    }

    /// The bend behind the ear: it starts this far back, turns over this length, and drops at
    /// this angle (60°) into the stub, which ends where the battery plugs on.
    private static let bendStart: CGFloat = 1.0
    private static let bendLength: CGFloat = 0.15
    private static let drop: CGFloat = 1.05
    private static let stubEnd: CGFloat = 1.25
    private static let step: CGFloat = 0.01

    /// The arm's centre line in its own plane — x back from the front's centre, y up — every
    /// 1 mm: dead straight and tapering a touch from the hinge, a smooth bend over the ear, then
    /// the stub, swelling toward the battery's size.
    private static let stations: [Station] = {
        var out: [Station] = []
        var point = CGPoint(x: armStart - 0.005, y: hingeHeight)
        var s = point.x
        while s <= stubEnd + 0.0001 {
            let angle = -drop * smooth((s - bendStart) / bendLength)
            let taper = smooth((s - armStart) / 0.8), swell = smooth((s - stubEnd + 0.1) / 0.1)
            let half = armHalf - 0.005 * taper + 0.012 * swell
            let width = armHalf / armAspect - 0.003 * taper + 0.007 * swell
            out.append(Station(point: point, angle: angle, half: half, width: width))
            point.x += cos(angle) * step
            point.y += sin(angle) * step
            s += step
        }
        return out
    }()

    /// The station `s` along the arm.
    private static func station(at s: CGFloat) -> Int {
        min(stations.count - 1, max(0, Int(((s - armStart + 0.005) / step).rounded())))
    }

    /// The arm as a tube swept along the stations in `range` (x back → -Z): a flattened
    /// rounded-rectangle section — the superellipse |x/a|³ + |y/b|³ = 1 — grown by `grow` all
    /// round. An extruded side profile could not do this: SCNShape's chamfer tears near half the
    /// section.
    private static func tube(_ range: ClosedRange<Int>, grow: CGFloat = 0) -> SCNGeometry {
        let segments = 28
        func power(_ v: CGFloat, _ p: CGFloat) -> CGFloat { copysign(pow(abs(v), p), v) }
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        for station in stations[range] {
            let along = CGPoint(x: cos(station.angle), y: sin(station.angle))
            let up = CGPoint(x: -along.y, y: along.x)
            let half = station.half + grow, width = station.width + grow
            for j in 0...segments {
                let theta = 2 * CGFloat.pi * CGFloat(j) / CGFloat(segments)
                let lift = half * power(sin(theta), 2 / 3)
                positions.append(SCNVector3(Float(width * power(cos(theta), 2 / 3)),
                                            Float(station.point.y + up.y * lift),
                                            Float(-(station.point.x + up.x * lift))))
                let across = power(cos(theta), 4 / 3) / width, rise = power(sin(theta), 4 / 3) / half
                let length = max(1e-6, hypot(across, rise))
                let (nx, nu) = (across / length, rise / length)
                normals.append(SCNVector3(Float(nx), Float(up.y * nu), Float(-(up.x * nu))))
            }
        }
        var indices: [Int32] = []
        let row = segments + 1
        for i in 0..<(range.count - 1) {
            for j in 0..<segments {
                let a = Int32(i * row + j), b = a + 1, c = a + Int32(row), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// The battery's centre and the way it points, in the arm's plane.
    private static var batteryPlacement: (centre: CGPoint, angle: CGFloat) {
        let end = stations[stations.count - 1]
        let gap: CGFloat = 0.003
        let reach = gap + battery.length / 2
        return (CGPoint(x: end.point.x + cos(end.angle) * reach, y: end.point.y + sin(end.angle) * reach), end.angle)
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

    /// Light grey print on nothing, centred: the INMO mark on the arm, the battery's label.
    private static func printed(_ text: String, size: CGSize, font: UIFont, kern: CGFloat, alpha: CGFloat,
                              ring: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let color = UIColor(white: 0.78, alpha: alpha)
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
            let bounds = label.size()
            var x = (size.width - bounds.width) / 2
            if ring {
                let d = size.height * 0.62
                let circle = CGRect(x: x - d * 0.75, y: (size.height - d) / 2, width: d, height: d)
                x += d * 0.45
                context.cgContext.setStrokeColor(color.cgColor)
                context.cgContext.setLineWidth(d * 0.12)
                context.cgContext.strokeEllipse(in: circle.insetBy(dx: d * 0.06, dy: d * 0.06))
            }
            label.draw(at: CGPoint(x: x, y: (size.height - bounds.height) / 2))
        }
    }

    private static let inmoMark = printed("INMO", size: CGSize(width: 320, height: 80),
                                        font: .systemFont(ofSize: 62, weight: .heavy), kern: 6, alpha: 0.75)
    private static let batteryLabel = printed("Replaceable design", size: CGSize(width: 1000, height: 120),
                                            font: .systemFont(ofSize: 70, weight: .medium), kern: 1, alpha: 0.55,
                                            ring: true)

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

    /// Matte dark gunmetal for the front — bead-blasted aluminium, a shade lighter than the arms,
    /// with a soft metallic sheen that the rounded edges catch.
    private static func frontFinish() -> SCNMaterial {
        pbr(UIColor(red: 0.34, green: 0.345, blue: 0.36, alpha: 1), roughness: 0.44, metalness: 0.7)
    }
    /// Satin black for the arms.
    private static func armFinish() -> SCNMaterial { pbr(UIColor(white: 0.045, alpha: 1), roughness: 0.4, clearCoat: 0.25) }
    /// The battery's black plastic, a touch flatter than the arms.
    private static func batteryFinish() -> SCNMaterial { pbr(UIColor(white: 0.05, alpha: 1), roughness: 0.5, clearCoat: 0.15) }
    private static func silver() -> SCNMaterial { pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.2, metalness: 1) }
    private static func red() -> SCNMaterial {
        pbr(UIColor(red: 0.86, green: 0.09, blue: 0.08, alpha: 1), roughness: 0.32, clearCoat: 0.6)
    }

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

    /// Printing on a lit surface: it takes the light like the surface under it.
    private static func decal(_ image: UIImage) -> SCNMaterial {
        let m = pbr(.white, roughness: 0.5)
        m.diffuse.contents = image
        m.diffuse.mipFilter = .linear
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
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

    /// The camera (or the sensor), flush in the front face: black glass in a thin bright ring,
    /// a dark hairline round that where it is set into the metal, and the lens element inside.
    private static func cameraLens(at position: SCNVector3) -> SCNNode {
        let lens = SCNNode()
        lens.position = position
        let facing = SCNVector3(Float.pi / 2, 0, 0)  // Y-axis primitives turned to face +Z
        let glass = pbr(UIColor(red: 0.01, green: 0.012, blue: 0.018, alpha: 1), roughness: 0.05, clearCoat: 1)
        let r = cameraRadius
        lens.addChildNode(node(SCNTube(innerRadius: r - 0.001, outerRadius: r + 0.0025, height: 0.0012),
                               pbr(UIColor(white: 0.03, alpha: 1), roughness: 0.6), at: SCNVector3Zero, euler: facing))
        lens.addChildNode(node(SCNTube(innerRadius: r - 0.0035, outerRadius: r, height: 0.0016), silver(),
                               at: SCNVector3Zero, euler: facing))
        lens.addChildNode(node(SCNCylinder(radius: r - 0.003, height: 0.0014), glass, at: SCNVector3Zero, euler: facing))
        lens.addChildNode(node(SCNCylinder(radius: r * 0.42, height: 0.0018),
                               pbr(UIColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1), roughness: 0.1, metalness: 0.7,
                                   clearCoat: 1),
                               at: SCNVector3Zero, euler: facing))
        return lens
    }

    static func makeNode() -> Parts {
        let root = SCNNode()
        let front = Float(frameDepth / 2), back = -front
        let face = frontFinish()

        let frame = extrude(frontOutline, depth: frameDepth, round: edgeRound)
        frame.shaderModifiers = [.geometry: wrapModifier]
        root.addChildNode(node(frame, face, face, face, face, face, at: SCNVector3Zero))
        // The saddle swells 0.6 mm out of the bridge's face — all of it rounded edge, so it reads
        // as the metal thickening rather than a plate laid on.
        root.addChildNode(node(extrude(saddleOutline, depth: 0.04, round: 0.011), face, face, face, face, face,
                               at: SCNVector3(0, 0, front - 0.014)))

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

            body.addChildNode(cameraLens(at: SCNVector3(x + side * Float(cameraCentre.x), Float(cameraCentre.y),
                                                        front + 0.0004)))

            // The end piece: the frame's corner turning back to the hinge, profile extruded
            // across its width and turned so the profile's x runs back along -Z.
            let endX = side * Float(halfWidth - endWidth / 2)
            body.addChildNode(node(extrude(endProfile, depth: endWidth, round: 0.012), face, face, face, face, face,
                                   at: SCNVector3(endX, 0, 0), euler: SCNVector3(0, Float.pi / 2, 0)))

            // The arm and everything on it hang off the hinge, turned back out of the wrap so
            // the arms run straight back.
            let armWidth = armHalf / armAspect
            let arm = SCNNode()
            arm.position = SCNVector3(side * Float(halfWidth - armWidth), 0, -Float(armStart))
            arm.eulerAngles.y = -side * Float(wrap)
            body.addChildNode(arm)
            func onArm(_ child: SCNNode) {
                child.position.z += Float(armStart)
                arm.addChildNode(child)
            }

            // The small red block at the hinge — low on its inner side, seen from below and
            // inside — and a thin red ring round the arm just behind it.
            onArm(node(SCNBox(width: armWidth + 0.004, height: armHalf + 0.004, length: 0.024,
                              chamferRadius: 0.005), red(),
                       at: SCNVector3(-side * Float(armWidth / 2), Float(hingeHeight - armHalf / 2),
                                      -Float(armStart) + 0.004)))
            onArm(node(tube(0...stations.count - 1), armFinish(), at: SCNVector3Zero))
            onArm(node(tube(station(at: 0.142)...station(at: 0.154), grow: 0.0008), red(), at: SCNVector3Zero))

            // The INMO mark on the outside of the arm, behind the ring.
            let markAt = stations[station(at: 0.21)]
            let mark = node(SCNPlane(width: 0.064, height: 0.016), decal(inmoMark),
                            at: SCNVector3(side * Float(markAt.width + 0.0006), Float(hingeHeight), -Float(markAt.point.x)),
                            euler: SCNVector3(0, side * .pi / 2, 0))
            onArm(mark)

            // The Power and GO keys: two slots under the right arm, near the front.
            for u: CGFloat in [0.32, 0.40] where side < 0 {
                let at = stations[station(at: u)]
                onArm(node(SCNBox(width: 0.02, height: 0.006, length: 0.05, chamferRadius: 0.003),
                           pbr(UIColor(white: 0.012, alpha: 1), roughness: 0.9),
                           at: SCNVector3(0, Float(hingeHeight - at.half + 0.002), -Float(u))))
            }

            // The battery stick, plugged onto the stub with a faint seam, its label outside.
            let (centre, angle) = batteryPlacement
            let stick = node(SCNBox(width: battery.thickness, height: battery.height, length: battery.length,
                                    chamferRadius: 0.014), batteryFinish(),
                             at: SCNVector3(0, Float(centre.y), -Float(centre.x)), euler: SCNVector3(Float(angle), 0, 0))
            let seam = node(SCNBox(width: battery.thickness - 0.012, height: battery.height - 0.014, length: 0.008,
                                   chamferRadius: 0.003), pbr(UIColor(white: 0.005, alpha: 1), roughness: 0.9),
                            at: SCNVector3(0, 0, Float(battery.length / 2) + 0.001))
            stick.addChildNode(seam)
            let label = node(SCNPlane(width: 0.21, height: 0.025), decal(batteryLabel),
                             at: SCNVector3(side * Float(battery.thickness / 2 + 0.0006), 0, -0.02),
                             euler: SCNVector3(0, side * .pi / 2, 0))
            stick.addChildNode(label)
            onArm(stick)

            // A clear silicone nose pad on a short metal arm behind each side of the arch.
            // Anchored on the frame's solid back face, and exactly as long as the gap it spans.
            let wireFrom = SCNVector3(side * 0.09, 0.02, back + 0.002)
            let padAt = SCNVector3(side * 0.1, -0.035, back - 0.055)
            let span = simd_distance(SIMD3<Float>(wireFrom), SIMD3<Float>(padAt))
            let wire = node(SCNCylinder(radius: 0.0035, height: CGFloat(span)), silver(),
                            at: SCNVector3((wireFrom.x + padAt.x) / 2, (wireFrom.y + padAt.y) / 2, (wireFrom.z + padAt.z) / 2))
            wire.simdLook(at: SIMD3(padAt), up: SIMD3(0, 0, 1), localFront: SIMD3(0, 1, 0))
            body.addChildNode(wire)
            let silicone = pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.3, clearCoat: 0.5)
            silicone.transparency = 0.25
            silicone.transparencyMode = .dualLayer
            let pad = node(SCNSphere(radius: 0.035), silicone, at: padAt, euler: SCNVector3(0.15, -side * 0.75, 0))
            pad.scale = SCNVector3(0.7, 1.15, 0.35)
            body.addChildNode(pad)
        }

        // Turn about the middle of the whole pair, not the front: from the front face back to the
        // battery's far end, and from the top down to its lowest corner.
        let (centre, angle) = batteryPlacement
        let along = CGPoint(x: cos(angle), y: sin(angle)), up = CGPoint(x: -along.y, y: along.x)
        var farthest: CGFloat = 0, low: CGFloat = 0
        for a: CGFloat in [-1, 1] {
            for b: CGFloat in [-1, 1] {
                let l = a * battery.length / 2, h = b * battery.height / 2
                farthest = max(farthest, centre.x + along.x * l + up.x * h)
                low = min(low, centre.y + along.y * l + up.y * h)
            }
        }
        let rear = -farthest
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
        /// Not `animated` for a still: an action only runs while a view draws the scene.
        func setLit(_ on: Bool, animated: Bool = true) {
            guard animated else {
                displays.forEach { $0.removeAction(forKey: "lit"); $0.opacity = on ? 1 : 0 }
                return
            }
            let fade = SCNAction.fadeOpacity(to: on ? 1 : 0, duration: 0.45)
            fade.timingMode = .easeOut
            displays.forEach { $0.runAction(fade, forKey: "lit") }
        }
    }
}
