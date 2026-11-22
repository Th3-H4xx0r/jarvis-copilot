import SceneKit
import UIKit

/// A procedural Ray-Ban Meta Scriber Optics (Gen 2): Ray-Ban's prescription-first smart frame,
/// RW7002, in Shiny Black with clear lenses. Every size here was measured in pixels off Ray-Ban's
/// own catalogue renders of that frame (front, side, three-quarter, back and folded, the shots
/// retailers carry as 0RW7002__2000__P21_*) and scaled by the size printed inside its temple,
/// 49□22 150: the two lens centres sit 49 + 22 = 71 mm apart, 9.96 px per mm on the front shot.
///
/// A soft panto front: each lens opening is wide and nearly square at the top and rounds in toward
/// the bottom, under a brow that rises from a low, flat keyhole bridge to its peak over the lens
/// and runs out into square end pieces. The 12 MP camera sits in the wearer's left end piece and
/// the white capture LED in the right one: matching 3.8 mm rings, 65 mm out from the middle. Tall
/// flat temples (10.5 mm at the hinge, swelling to 13 mm over the battery, a 7 mm waist) run back
/// with a slight droop and bend down behind the ear. The capture button is a metal strip on top of
/// the right temple, the power switch a grey slider inside it.
///
/// Scene units are decimetres, as for the INMO GO3, so a number in millimetres reads ÷ 100. The
/// front faces +Z, the temples run back along -Z, "right" is the wearer's (the -X side), and Y = 0
/// is the lens centre line.
enum MetaGlassesModel {
    /// Leans the top toward the camera so the lenses and the near temple both read.
    static let defaultTilt: Float = 0.3
    /// Camera distances for the square card and a wide page hero. The field of view is vertical, so
    /// a wide frame takes a closer camera than the card.
    static let cardDistance: Float = 4.2
    static let heroDistance: Float = 3.4

    /// A frame finish: the acetate's colour and gloss, and the tint over the lenses. One place to
    /// switch to another Scriber colourway.
    struct Colourway {
        /// The acetate under its clear coat, linear-ish RGB.
        var frame: (red: CGFloat, green: CGFloat, blue: CGFloat)
        var roughness: CGFloat
        /// Laid over the clear glass; the alpha is its strength.
        var lensTint: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

        /// Shiny Black with clear lenses (RW7002 2000), his pair: a deep black with a breath of
        /// blue in it so the gloss doesn't go flat.
        static let shinyBlack = Colourway(frame: (0.014, 0.0145, 0.018), roughness: 0.17,
                                          lensTint: (0.86, 0.91, 1, 0.004))
    }

    /// The finish the model is drawn in.
    static let colourway = Colourway.shinyBlack

    // MARK: Measurements (mm)

    /// The straight-on shot looks down about 7° onto a front that leans back 11.5°, so its heights
    /// read 5.5% short (that is why its lens opening measured 38.8 mm against the 43.4 mm the
    /// frame is sold as, less its groove); every height taken off it is stretched back by this.
    private static let frontRise: CGFloat = 1.055
    /// The side shot's scale: 9.31 px per mm, set by the 150 mm temple (hinge to tip, along its
    /// middle). Its numbers below were first read at 10 px per mm, so they grow by this.
    private static let sideScale: CGFloat = 10 / 9.31

    /// Millimetres to scene units.
    private static func u(_ mm: CGFloat) -> CGFloat { mm / 100 }
    private static func p(_ point: (CGFloat, CGFloat)) -> CGPoint { CGPoint(x: point.0 / 100, y: point.1 / 100) }
    /// A point off the straight-on shot, its height stretched back (frontRise).
    private static func pf(_ point: (CGFloat, CGFloat)) -> CGPoint { p((point.0, point.1 * frontRise)) }

    /// The front's outline, the wearer's right half (-X), measured on the straight-on shot from the
    /// top of the bridge out along the brow, down the end piece and the outer rim, along the bottom,
    /// up the rim beside the nose and round the keyhole to the middle of the bridge's underside.
    /// The brow peaks at 24.4 mm over the lens, the bridge's flat top is 17.8 and its underside 9.9,
    /// the end piece reaches 71.3 mm out, the bottom 21.9 mm down.
    private static let frontHalf: [(CGFloat, CGFloat)] = [
        (-4, 17.8), (-7.5, 17.78), (-10.0, 17.9), (-12.6, 18.75), (-15.1, 20.05), (-17.6, 21.15),
        (-20.1, 22.05), (-22.6, 22.85), (-25.1, 23.38), (-27.6, 23.78), (-30.1, 24.06), (-32.6, 24.26),
        (-35.1, 24.36), (-37.7, 24.44), (-40.2, 24.44), (-42.7, 24.38), (-45.2, 24.28), (-47.7, 24.15),
        (-50.2, 23.98), (-52.7, 23.8), (-55.2, 23.58), (-57.7, 23.27), (-60.3, 22.95), (-62.8, 22.65),
        (-65.3, 22.3), (-67.6, 21.62), (-69.6, 20.95), (-70.8, 20.2), (-71.3, 19.1),
        (-71.35, 17.0), (-71.3, 14.0), (-71.05, 12.1), (-70.4, 10.8), (-68.6, 9.6), (-66.3, 8.2),
        (-65.1, 6.7), (-64.3, 5.2), (-63.7, 3.7), (-63.1, 2.2), (-62.6, 0.65), (-62.0, -0.85),
        (-61.5, -2.4), (-60.9, -3.9), (-60.3, -5.4), (-59.6, -6.9), (-58.8, -8.4), (-57.9, -9.9),
        (-57.0, -11.4), (-55.9, -12.9), (-54.7, -14.4), (-53.2, -15.9), (-51.3, -17.4), (-48.8, -18.9),
        (-45.3, -20.3), (-42.7, -21.05), (-40.2, -21.5), (-37.7, -21.8), (-35.1, -21.9), (-32.6, -21.88),
        (-30.1, -21.62), (-27.6, -21.2), (-25.1, -20.6), (-22.6, -19.75), (-20.3, -18.75), (-18.1, -17.4),
        (-16.2, -15.9), (-14.7, -14.4), (-13.3, -12.9), (-12.1, -11.4), (-11.2, -9.9), (-10.4, -8.4),
        (-9.6, -6.9), (-8.9, -5.4), (-8.3, -3.9), (-7.8, -2.4), (-7.3, -0.85), (-6.95, 0.65),
        (-6.65, 2.2), (-6.5, 3.7), (-6.45, 5.2), (-6.5, 6.7), (-6.3, 8.2), (-5.6, 9.35), (-4.3, 9.88),
        (-2, 9.95),
    ]

    /// The wearer's right lens opening as it shows from the front: 47.4 × 38.8 mm, its inner edge
    /// 11.9 mm from the middle and its outer edge 59.3. Near-straight up the outer side, the top
    /// corner beside the nose softly rounded, the bottom rounding in. (Its top outer corner is
    /// hidden by the temple on the front shot and was taken from the back shot.)
    private static let lensHalf: [(CGFloat, CGFloat)] = [
        (-38.0, 19.4), (-34.1, 19.33), (-30.5, 19.1), (-27.7, 18.8), (-24.7, 18.2), (-22.6, 17.6),
        (-20.9, 17.0), (-19.6, 16.4), (-18.5, 15.8), (-17.5, 15.2), (-16.7, 14.6), (-15.9, 14.0),
        (-14.7, 12.8), (-13.8, 11.6), (-13.1, 10.4), (-12.6, 9.2), (-12.3, 8.0), (-12.0, 6.8),
        (-11.9, 5.0), (-11.9, 3.2), (-12.1, 1.4), (-12.4, -0.5), (-12.8, -2.3), (-13.3, -4.1),
        (-13.9, -5.9), (-14.6, -7.7), (-15.8, -9.5), (-17.0, -11.3), (-18.4, -13.1), (-20.3, -14.9),
        (-22.0, -16.1), (-24.3, -17.3), (-27.7, -18.5), (-30.1, -19.1), (-35.0, -19.4), (-39.6, -19.1),
        (-42.7, -18.5), (-46.1, -17.3), (-48.3, -16.1), (-49.9, -14.9), (-51.7, -13.1), (-53.1, -11.3),
        (-54.2, -9.5), (-55.2, -7.7), (-56.0, -5.9), (-56.8, -4.1), (-57.4, -2.3), (-57.9, -0.5),
        (-58.4, 1.4), (-58.8, 3.2), (-59.1, 5.0), (-59.3, 6.8), (-59.3, 8.6), (-59.0, 10.4),
        (-58.6, 12.2), (-58.0, 13.4), (-57.1, 14.6), (-55.9, 15.8), (-54.9, 16.5), (-53.1, 17.4),
        (-50.8, 18.3), (-47.5, 18.95), (-44.0, 19.3),
    ]

    /// The front is 5.2 mm deep (edge-on on the side shot), its edges rounded off 1.2 mm.
    private static let frontDepth: CGFloat = 4.8 * sideScale
    private static let frontRound: CGFloat = 1.2
    /// The front curves back as it goes out: 2.5 mm at the end pieces (side shot), a gentle arc.
    private static let bend = 2.5 / (71.3 * 71.3)
    /// The front leans back at the bottom (the pantoscopic tilt on the side shot), about the top of
    /// the end pieces.
    private static let lean: CGFloat = 11.5 * .pi / 180
    /// The end pieces' top (and the temples'), 22 mm up, just under the brow's corner.
    private static let hingeTop: CGFloat = 20.9 * frontRise
    /// The camera and the LED: rings 3.8 mm across, centred 65.3 mm out and 15.6 mm up.
    private static let eye = (x: CGFloat(65.3), y: CGFloat(14.8 * frontRise), ring: CGFloat(1.9))
    /// The end piece runs 11.4 mm back from the front face to the hinge seam; temple and end piece
    /// are 5 mm thick (outer face flush with the front's edge at 71.3) and 11.3 mm tall there.
    private static let endDepth: CGFloat = 10.6 * sideScale
    private static let sideHeight: CGFloat = 10.5 * sideScale
    private static let sideThickness: CGFloat = 5.0
    private static let sideCentre: CGFloat = 71.3 - 2.5
    private static let sideRound: CGFloat = 1.0

    /// The temple seen from outside, u back from the hinge seam and v down from its top, as read off
    /// the side shot at 10 px per mm (sideScale grows it to size; its top edge lowered 0.9 mm where
    /// the shot looks onto the top): it droops gently, swells under the battery to 14 mm at 75 mm,
    /// pinches to a 7.4 mm waist at 96 mm and bends down past the ear to a rounded tip 141 mm back
    /// and 36 mm down.
    private static let templeTopEdge: [(CGFloat, CGFloat)] = measuredTopEdge.map { ($0.0 * sideScale, $0.1 * sideScale) }
    private static let templeBottomEdge: [(CGFloat, CGFloat)] = measuredBottomEdge.map { ($0.0 * sideScale, $0.1 * sideScale) }
    private static let measuredTopEdge: [(CGFloat, CGFloat)] = [
        (1.0, 0), (9.7, -0.1), (15.7, -0.3), (19.7, -0.45), (23.7, -0.6), (29.7, -0.85), (35.7, -1.1),
        (39.7, -1.35), (45.7, -1.7), (49.7, -2.0), (55.7, -2.4), (59.7, -2.75), (63.7, -3.05),
        (69.7, -3.4), (73.7, -3.7), (77.7, -4.15), (81.7, -4.7), (85.7, -5.4), (89.7, -6.1),
        (93.7, -6.85), (97.7, -7.7), (101.7, -8.9), (105.7, -10.4), (109.7, -12.3), (113.7, -14.9),
        (117.7, -18.1), (121.7, -21.9), (125.7, -26.3), (128.7, -30.0), (130.4, -32.5),
    ]
    private static let measuredBottomEdge: [(CGFloat, CGFloat)] = [
        (130.5, -35.4), (129.7, -35.95), (127.7, -36.75), (125.7, -37.2), (123.7, -37.3), (121.7, -36.9),
        (119.7, -35.9), (117.7, -33.5), (115.7, -30.1), (113.7, -26.7), (111.7, -23.6), (109.7, -20.8),
        (107.7, -18.5), (105.7, -16.9), (103.7, -15.7), (101.7, -14.8), (99.7, -14.1), (97.7, -13.6),
        (95.7, -13.3), (93.7, -13.1), (91.7, -13.0), (89.7, -13.0), (87.7, -13.05), (85.7, -13.2),
        (83.7, -13.5), (81.7, -13.95), (79.7, -14.5), (77.7, -15.1), (75.7, -15.8), (73.7, -16.3),
        (71.7, -16.5), (69.7, -16.5), (65.7, -16.3), (59.7, -15.8), (49.7, -14.9), (39.7, -13.9),
        (29.7, -12.9), (19.7, -11.7), (9.7, -10.6), (1.0, -10.5),
    ]

    /// How far each temple turns in to fold: the left lies flat behind the front, the right
    /// rests on it at a slight angle.
    private static func foldAngle(_ side: Float) -> Float { side > 0 ? 1.56 : 1.45 }

    // MARK: Outlines

    /// A closed, smooth outline through measured points (Catmull-Rom, drawn as cubic Béziers).
    private static func smoothClosed(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

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

    private static func mirrored(_ half: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        half.reversed().map { (-$0.0, $0.1) }
    }

    /// The whole front, lens openings cut out.
    private static var frontOutline: CGPath {
        let outline = [(CGFloat(0), CGFloat(17.8))] + frontHalf + [(0, 9.95)] + mirrored(frontHalf)
        return smoothClosed(outline.map(pf))
            .subtracting(lensOutline(side: -1))
            .subtracting(lensOutline(side: 1))
    }

    /// A lens opening (side -1 is the wearer's right), grown by grow all round.
    private static func lensOutline(side: CGFloat, grow: CGFloat = 0) -> CGPath {
        let points = side < 0 ? lensHalf : mirrored(lensHalf)
        let outline = smoothClosed(points.map(pf))
        guard grow > 0 else { return outline }
        return outline.union(outline.copy(strokingWithWidth: grow * 2, lineCap: .round, lineJoin: .round,
                                          miterLimit: 2))
    }

    /// The end piece seen from outside (u back from the seam, v down from the top): a block from
    /// inside the front back to the seam, its front cut to the front's lean so it stays buried.
    private static var endProfile: CGPath {
        let h = sideHeight, r = sideRound
        return roundedPolygon([
            (p((-endDepth + 1.0, 0)), 0),
            (p((0, 0)), u(r)),
            (p((0, -h)), u(r)),
            (p((-endDepth + 1.0 + h * tan(lean), -h)), 0),
        ])
    }

    /// The temple seen from outside, as measured: its front end square to the seam with small
    /// rounded corners, the rest a smooth outline through the measured edges.
    private static var templeProfile: CGPath {
        let h = sideHeight
        let front: [(CGFloat, CGFloat)] = [(0.12, -h + 0.55), (0, -h + 1.3), (0, -1.3), (0.12, -0.55)]
        return smoothClosed((front + templeTopEdge + templeBottomEdge).map(p))
    }

    /// The temple's top this many mm back from the seam, in mm.
    private static func templeTop(at s: CGFloat) -> CGFloat {
        let edge = templeTopEdge
        guard let upper = edge.firstIndex(where: { $0.0 >= s }) else { return edge[edge.count - 1].1 }
        guard upper > 0 else { return edge[0].1 }
        let (a, b) = (edge[upper - 1], edge[upper])
        return a.1 + (b.1 - a.1) * (s - a.0) / (b.0 - a.0)
    }

    /// The temple's underside this many mm back from the seam, in mm (the straight part, ahead of
    /// the bend).
    private static func templeBottom(at s: CGFloat) -> CGFloat {
        let edge = templeBottomEdge.reversed().map { $0 }
        guard let upper = edge.firstIndex(where: { $0.0 >= s }) else { return edge[edge.count - 1].1 }
        guard upper > 0 else { return edge[0].1 }
        let (a, b) = (edge[upper - 1], edge[upper])
        return a.1 + (b.1 - a.1) * (s - a.0) / (b.0 - a.0)
    }

    /// A rounded edge rather than a flat chamfer: a quarter round from the face to the side.
    private static let roundProfile: UIBezierPath = {
        let profile = UIBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        profile.addQuadCurve(to: CGPoint(x: 1, y: 0), controlPoint: CGPoint(x: 1, y: 1))
        profile.flatness = 0.03
        return profile
    }()

    /// An outline extruded along Z with rounded edges. The default flatness is in points and the
    /// model is a unit or so across. SceneKit silently builds no mesh at all for the long front
    /// below 0.003 here (seen at 0.0022 and 0.0015 on iOS), so it takes that.
    private static func extrude(_ path: CGPath, depth: CGFloat, round: CGFloat, flatness: CGFloat = 0.0015) -> SCNShape {
        let bezier = UIBezierPath(cgPath: path)
        bezier.usesEvenOddFillRule = true
        bezier.flatness = flatness
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.chamferRadius = round
        shape.chamferProfile = roundProfile
        return shape
    }

    /// The front's curve, applied as it is drawn (SCNShape only builds its mesh then): each point
    /// moves back by bend·x², its normal tilted to match. Things fixed to the front ride the same
    /// curve (onFront in makeNode).
    private static let bendModifier: String = {
        let c = bend * 100  // per scene unit
        return """
            float x = _geometry.position.x;
            _geometry.position.z -= \(c) * x * x;
            float3 n = _geometry.normal;
            _geometry.normal = normalize(float3(n.x + \(2 * c) * x * n.z, n.y, n.z));
            """
    }()

    /// How far the front's curve sets a point this many mm out back, in mm, and the angle it faces.
    private static func curve(at x: CGFloat) -> (back: CGFloat, angle: Float) {
        (bend * x * x, Float(atan(2 * bend * x)))
    }

    // MARK: Textures

    /// A soft round glow: the LED's light on the acetate round it.
    private static let glowImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 1, alpha: 0.85).cgColor,
                          UIColor(white: 1, alpha: 0.3).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.12, 0.32, 1]) else { return }
            let centre = CGPoint(x: 64, y: 64)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                                 endRadius: 64, options: [])
        }
    }()

    /// A soft-edged ring: the focus marker's ripple.
    private static let ringImage: UIImage = {
        let size = CGSize(width: 160, height: 160)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            g.setShadow(offset: .zero, blur: 9, color: UIColor.white.cgColor)
            g.setStrokeColor(UIColor.white.cgColor)
            g.setLineWidth(8)
            g.strokeEllipse(in: CGRect(x: 18, y: 18, width: 124, height: 124))
        }
    }()

    /// The touchpad: a satin panel along the right temple's outer face.
    private static let touchpadImage: UIImage = {
        let size = CGSize(width: 720, height: 152)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.03, alpha: 0.07).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4), cornerRadius: 60).fill()
        }
    }()

    /// A product studio for the reflections (an equirectangular image): a dark room, a broad
    /// softbox overhead, a key box front left, tall strip lights either side and a rim strip
    /// behind, each with a soft edge. Glossy black acetate is seen almost only through these, so
    /// they draw the frame's crisp edges on the app's black.
    static let studio: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            let colors = [UIColor(white: 0.13, alpha: 1).cgColor, UIColor(white: 0.045, alpha: 1).cgColor,
                          UIColor(white: 0.006, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                g.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            func softbox(_ rect: CGRect, _ level: CGFloat, radius: CGFloat = 10) {
                for step in stride(from: 6, through: 0, by: -1) {
                    let grow = CGFloat(step) * 5
                    UIColor(white: level, alpha: step == 0 ? 1 : 0.16).setFill()
                    UIBezierPath(roundedRect: rect.insetBy(dx: -grow, dy: -grow), cornerRadius: radius + grow).fill()
                }
            }
            softbox(CGRect(x: 250, y: 18, width: 524, height: 70), 1, radius: 30)    // overhead
            softbox(CGRect(x: 400, y: 150, width: 110, height: 120), 0.9)             // key, front left
            softbox(CGRect(x: 130, y: 120, width: 34, height: 260), 0.8, radius: 6)   // strip, one side
            softbox(CGRect(x: 860, y: 120, width: 34, height: 260), 0.8, radius: 6)   // strip, the other
            softbox(CGRect(x: -20, y: 150, width: 46, height: 200), 0.7, radius: 6)   // rim strip behind
            softbox(CGRect(x: 998, y: 150, width: 46, height: 200), 0.7, radius: 6)
            UIColor(white: 0.05, alpha: 1).setFill()                                   // floor bounce
            g.fill(CGRect(x: 0, y: 470, width: size.width, height: 42))
        }
    }()

    /// The lens plane: 52 × 44 mm about the lens's box centre, 0.1 mm a pixel.
    private static let lensPlane = (width: CGFloat(0.52), height: CGFloat(0.44), centreX: CGFloat(0.356))

    /// The glass for one lens, drawn about its plane's centre.
    private static func glassImage(side: CGFloat) -> UIImage {
        let size = CGSize(width: lensPlane.width * 1000, height: lensPlane.height * 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            g.translateBy(x: size.width / 2, y: size.height / 2)
            g.scaleBy(x: 1000, y: -1000)
            g.translateBy(x: -side * lensPlane.centreX, y: 0)
            let outline = lensOutline(side: side, grow: u(0.4))
            g.addPath(outline)
            g.clip()
            let tint = colourway.lensTint
            UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha).setFill()
            g.fill(CGRect(x: -0.8, y: -0.3, width: 1.6, height: 0.6))
            func sheen(from: CGPoint, to: CGPoint, _ stops: [(CGFloat, CGFloat)]) {
                let colors = stops.map { UIColor(red: 0.92, green: 0.96, blue: 1, alpha: $0.1).cgColor } as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                                locations: stops.map { $0.0 }) else { return }
                g.drawLinearGradient(gradient, start: from, end: to, options: [])
            }
            let cx = side * lensPlane.centreX
            // SceneKit blends in linear light, so these few percent already read as a soft gleam.
            sheen(from: CGPoint(x: cx, y: 0.21), to: CGPoint(x: cx, y: 0.05), [(0, 0.024), (1, 0)])
            sheen(from: CGPoint(x: cx - side * 0.2, y: 0.2), to: CGPoint(x: cx + side * 0.2, y: -0.2),
                  [(0.33, 0), (0.41, 0.022), (0.47, 0), (0.55, 0), (0.58, 0.012), (0.61, 0)])
            // The lens's edge catching the light just inside the rim.
            g.addPath(outline)
            g.setStrokeColor(UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 0.05).cgColor)
            g.setLineWidth(u(1.2))
            g.strokePath()
        }
    }

    /// Print on nothing, centred, size in pixels.
    private static func printed(_ text: String, size: CGSize, font: UIFont, color: UIColor, kern: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
            let bounds = label.size()
            label.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
    }

    /// The silver Ray-Ban script on the outside of each temple.
    private static let logo = printed("Ray-Ban", size: CGSize(width: 660, height: 200),
                                      font: UIFont(name: "SnellRoundhand-Black", size: 128) ?? .italicSystemFont(ofSize: 110),
                                      color: UIColor(white: 0.92, alpha: 1))
    /// Inside the right temple, as on the frame.
    private static let modelLine = printed("RAY-BAN META · SCRIBER OPTICS · (GEN 2) · ESSILORLUXOTTICA",
                                           size: CGSize(width: 1400, height: 48),
                                           font: .systemFont(ofSize: 34, weight: .medium),
                                           color: UIColor(white: 0.8, alpha: 0.7), kern: 1)
    /// The Meta mark on the left temple's inner plate.
    private static let metaMark = printed("∞", size: CGSize(width: 200, height: 80),
                                          font: .systemFont(ofSize: 76, weight: .regular), color: UIColor(white: 0.12, alpha: 0.9))

    // MARK: Materials

    private static func pbr(_ color: UIColor, roughness: CGFloat, metalness: CGFloat = 0,
                            clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.clearCoat.contents = clearCoat
        m.clearCoatRoughness.contents = 0.05
        return m
    }

    /// Shiny black injected acetate: near-black under a glossy clear coat, so the frame reads by
    /// its reflections on the app's black.
    private static func acetate() -> SCNMaterial {
        let c = colourway.frame
        let m = pbr(UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1), roughness: colourway.roughness, clearCoat: 1)
        m.clearCoatRoughness.contents = 0.025
        return m
    }
    /// Brushed gunmetal for the hinge plates and sliders; polished steel for the barrel and the
    /// capture button.
    private static func gunmetal() -> SCNMaterial { pbr(UIColor(red: 0.4, green: 0.4, blue: 0.42, alpha: 1), roughness: 0.34, metalness: 1) }
    private static func silver() -> SCNMaterial { pbr(UIColor(white: 0.8, alpha: 1), roughness: 0.24, metalness: 1) }

    /// Clear prescription lenses, unlit so they read the same from any side: a breath of tint and
    /// soft studio reflections cut to the lens, so the glass shows on the app's black while the
    /// frame and temples behind it show through.
    private static func lensGlass(side: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = glassImage(side: side)
        m.diffuse.mipFilter = .linear
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    /// Mic pinholes and speaker grilles: dark and matte.
    private static func port() -> SCNMaterial { pbr(UIColor(white: 0.004, alpha: 1), roughness: 0.85) }

    /// A focus marker's light: unlit and added, so it glows on the black; tinted per pulse.
    private static func markerMaterial(_ image: UIImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.diffuse.mipFilter = .linear
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    /// Printing on a lit surface: it takes the light like the surface under it.
    private static func decal(_ image: UIImage, roughness: CGFloat = 0.35, metalness: CGFloat = 0) -> SCNMaterial {
        let m = pbr(.white, roughness: roughness, metalness: metalness)
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
        /// The capture LED's emitter and its glow on the frame.
        let led: SCNNode
        let ledGlow: SCNNode
        /// Each temple's hinge, turned about Y to fold, with its side (+1 the wearer's left).
        let hinges: [(node: SCNNode, side: Float)]
        /// Each part's focus markers (hidden until focused), the first one the camera centres on.
        let markers: [MetaGlassesPart: [SCNNode]]
        /// The pair under the turntable, and where it sits open and folded so it turns about its
        /// own middle either way.
        let root: SCNNode
        let openCentre: SCNVector3
        let foldedCentre: SCNVector3
    }

    /// A focus marker, facing +Z: a glow and three rings, hidden until a part is focused.
    private static func focusMarker(radius: CGFloat) -> SCNNode {
        let marker = SCNNode()
        marker.isHidden = true
        let size = u(radius * 2)
        let glow = node(SCNPlane(width: size, height: size), markerMaterial(glowImage), at: SCNVector3Zero)
        glow.name = "glow"
        marker.addChildNode(glow)
        for index in 0..<3 {
            let ring = node(SCNPlane(width: size, height: size), markerMaterial(ringImage),
                            at: SCNVector3(0, 0, Float(index + 1) * 0.0002))
            ring.name = "ring\(index)"
            marker.addChildNode(ring)
        }
        marker.enumerateHierarchy { child, _ in child.renderingOrder = 30 }
        return marker
    }

    private static func node(_ geometry: SCNGeometry, _ materials: SCNMaterial..., at position: SCNVector3,
                             euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geometry.materials = materials
        let node = SCNNode(geometry: geometry)
        node.position = position
        node.eulerAngles = euler
        return node
    }

    private static func v3(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
        SCNVector3(Float(u(x)), Float(u(y)), Float(u(z)))
    }

    /// Y-axis primitives turned to face +Z.
    private static let facing = SCNVector3(Float.pi / 2, 0, 0)

    /// The camera or the LED, set into the end piece's face: a dark polished ring round black glass,
    /// and inside it the camera's violet-coated lens, or the LED's small emitter.
    private static func eyePiece(isCamera: Bool) -> (node: SCNNode, emitter: SCNNode?) {
        let piece = SCNNode()
        let r = eye.ring
        piece.addChildNode(node(SCNTube(innerRadius: u(r - 0.42), outerRadius: u(r), height: u(0.5)),
                                pbr(UIColor(white: 0.16, alpha: 1), roughness: 0.18, metalness: 1),
                                at: SCNVector3Zero, euler: facing))
        piece.addChildNode(node(SCNCylinder(radius: u(r - 0.4), height: u(0.36)),
                                pbr(UIColor(white: 0.008, alpha: 1), roughness: isCamera ? 0.04 : 0.3, clearCoat: 1),
                                at: SCNVector3Zero, euler: facing))
        guard isCamera else {
            let emitter = node(SCNCylinder(radius: u(0.62), height: u(0.42)),
                               pbr(UIColor(white: 0.16, alpha: 1), roughness: 0.4), at: SCNVector3Zero, euler: facing)
            emitter.geometry?.firstMaterial?.emission.contents = UIColor.white
            emitter.geometry?.firstMaterial?.emission.intensity = 0
            piece.addChildNode(emitter)
            return (piece, emitter)
        }
        piece.addChildNode(node(SCNCylinder(radius: u(0.95), height: u(0.44)),
                                pbr(UIColor(red: 0.16, green: 0.07, blue: 0.3, alpha: 1), roughness: 0.08, metalness: 0.7,
                                    clearCoat: 1),
                                at: SCNVector3Zero, euler: facing))
        piece.addChildNode(node(SCNCylinder(radius: u(0.42), height: u(0.48)),
                                pbr(UIColor(red: 0.02, green: 0.01, blue: 0.05, alpha: 1), roughness: 0.05, clearCoat: 1),
                                at: SCNVector3Zero, euler: facing))
        return (piece, nil)
    }

    static func makeNode() -> Parts {
        let root = SCNNode()
        let frontFace = frontDepth / 2

        // The front, leaning back about the top of the end pieces; everything fixed to it rides
        // in its node and on its curve.
        let lean = SCNNode()
        lean.position = v3(0, hingeTop, frontFace)
        lean.eulerAngles.x = Float(Self.lean)
        root.addChildNode(lean)
        let front = SCNNode()
        front.position = v3(0, -hingeTop, -frontFace)
        lean.addChildNode(front)
        func onFront(_ child: SCNNode, x: CGFloat, y: CGFloat, z: CGFloat) {
            let (back, angle) = curve(at: x)
            child.position = v3(x, y, z - back)
            child.eulerAngles.y += angle
            front.addChildNode(child)
        }

        let shell = acetate()
        let frame = extrude(frontOutline, depth: u(frontDepth), round: u(frontRound), flatness: 0.003)
        frame.shaderModifiers = [.geometry: bendModifier]
        front.addChildNode(node(frame, shell, shell, shell, shell, shell, at: SCNVector3Zero))

        // The clear lenses, sat in the rims' grooves, on the front's curve.
        for side: CGFloat in [-1, 1] {
            let lens = SCNPlane(width: lensPlane.width, height: lensPlane.height)
            lens.shaderModifiers = [.geometry: """
                float x = \(side * lensPlane.centreX) + _geometry.position.x;
                _geometry.position.z -= \(bend * 100) * x * x;
                """]
            let glass = node(lens, lensGlass(side: side), at: v3(side * lensPlane.centreX * 100, 0, 0))
            glass.renderingOrder = 10
            front.addChildNode(glass)
        }

        // The camera in the wearer's left end piece, the LED in the right.
        let camera = eyePiece(isCamera: true)
        onFront(camera.node, x: eye.x, y: eye.y, z: frontFace + 0.1)
        let led = eyePiece(isCamera: false)
        onFront(led.node, x: -eye.x, y: eye.y, z: frontFace + 0.1)
        let glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = glowImage
        glowMaterial.blendMode = .add
        glowMaterial.writesToDepthBuffer = false
        let glow = node(SCNPlane(width: u(8), height: u(8)), glowMaterial, at: SCNVector3Zero)
        glow.opacity = 0
        glow.renderingOrder = 20
        onFront(glow, x: -eye.x, y: eye.y, z: frontFace + 0.32)

        var markers: [MetaGlassesPart: [SCNNode]] = [:]
        func mark(_ part: MetaGlassesPart, _ marker: SCNNode) { markers[part, default: []].append(marker) }
        let cameraMarker = focusMarker(radius: 7)
        onFront(cameraMarker, x: eye.x, y: eye.y, z: frontFace + 0.7)
        mark(.camera, cameraMarker)
        let ledMarker = focusMarker(radius: 7)
        onFront(ledMarker, x: -eye.x, y: eye.y, z: frontFace + 0.7)
        mark(.led, ledMarker)

        // The mics: a grey grille strip under the bridge (it shows on the back shot), and a pinhole
        // under each end piece by the hinge (below).
        front.addChildNode(node(SCNBox(width: u(6.4), height: u(0.4), length: u(1.6), chamferRadius: u(0.15)), gunmetal(),
                                at: v3(0, 9.95 * frontRise - 0.1, 0)))
        let bridgeMic = focusMarker(radius: 7.5)
        bridgeMic.eulerAngles.x = .pi / 2
        onFront(bridgeMic, x: 0, y: 9.95 * frontRise - 0.8, z: 0)
        mark(.mic, bridgeMic)

        // The nose pads: soft acetate pads on the back of the rims either side of the nose.
        for side: CGFloat in [-1, 1] {
            let pad = node(SCNSphere(radius: u(1)), shell, at: SCNVector3Zero)
            pad.scale = SCNVector3(2.0, 5.2, 2.0)
            pad.eulerAngles = SCNVector3(0.15, Float(side) * 0.5, Float(side) * 0.28)
            onFront(pad, x: side * 9.4, y: -2 * frontRise, z: -frontFace - 1.4)
        }

        var hinges: [(node: SCNNode, side: Float)] = []
        for side: Float in [-1, 1] {
            let s = CGFloat(side)
            // The side: end piece and temple, square to the world rather than the front's lean,
            // from the hinge seam at the top of the end piece.
            let sideNode = SCNNode()
            sideNode.position = v3(s * sideCentre, hingeTop, frontFace - endDepth - curve(at: sideCentre).back)
            root.addChildNode(sideNode)
            let outward = Float.pi / 2  // a profile drawn in (u, v) turned so u runs back along -Z
            sideNode.addChildNode(node(extrude(endProfile, depth: u(sideThickness), round: u(sideRound)),
                                       shell, shell, shell, shell, shell, at: SCNVector3Zero,
                                       euler: SCNVector3(0, outward, 0)))
            let inner = -s * sideThickness / 2  // the inner face, from the side's centre
            let k = sideScale, mid = -sideHeight / 2  // side-shot numbers to size; half way down the side
            // The hinge: a gunmetal plate on the inside across the seam, the silver barrel in it.
            sideNode.addChildNode(node(SCNBox(width: u(0.8), height: u(7.4 * k), length: u(3.4), chamferRadius: u(0.3)),
                                       gunmetal(), at: v3(inner - s * 0.3, mid, 1.7)))
            sideNode.addChildNode(node(SCNCylinder(radius: u(1.0), height: u(6.4 * k)), silver(),
                                       at: v3(inner + s * 0.2, mid, 0)))
            // A mic pinhole under the end piece, by the hinge.
            sideNode.addChildNode(node(SCNCylinder(radius: u(0.4), height: u(0.4)), port(), at: v3(0, -sideHeight, 4.5)))
            let hingeMic = focusMarker(radius: 7)
            hingeMic.eulerAngles.x = .pi / 2
            hingeMic.position = v3(0, -sideHeight - 0.8, 4.5)
            sideNode.addChildNode(hingeMic)
            mark(.mic, hingeMic)

            let hinge = SCNNode()
            hinge.position = v3(inner, 0, 0)
            sideNode.addChildNode(hinge)
            hinges.append((hinge, side))
            func onTemple(_ child: SCNNode) { hinge.addChildNode(child) }
            let centre = s * sideThickness / 2  // the temple's middle, from the hinge (its inner face)

            onTemple(node(extrude(templeProfile, depth: u(sideThickness), round: u(sideRound)),
                          shell, shell, shell, shell, shell, at: v3(centre, 0, 0), euler: SCNVector3(0, outward, 0)))
            onTemple(node(SCNBox(width: u(0.8), height: u(7.4 * k), length: u(3.6), chamferRadius: u(0.3)), gunmetal(),
                          at: v3(-s * 0.3, mid, -1.85)))
            // The Ray-Ban script on the outside, just behind the seam.
            onTemple(node(SCNPlane(width: u(11.2 * k), height: u(3.4 * k)), decal(logo, roughness: 0.25, metalness: 0.8),
                          at: v3(centre + s * (sideThickness / 2 + 0.03), templeTop(at: 9.4 * k) - 6.0 * k, -9.4 * k),
                          euler: SCNVector3(0, side * .pi / 2, 0)))

            // The open-ear speaker's grille under the temple, just ahead of the ear, and the slot
            // along the top over it (on the side shot, 67–81 mm back).
            let grilleAt = 68 * k
            onTemple(node(SCNBox(width: u(1.5), height: u(0.5), length: u(13 * k), chamferRadius: u(0.2)), port(),
                          at: v3(centre, templeBottom(at: grilleAt) + 0.12, -grilleAt)))
            let slope = Float(atan((templeTop(at: 81 * k) - templeTop(at: 67 * k)) / (14 * k)))
            onTemple(node(SCNBox(width: u(1.0), height: u(0.4), length: u(14 * k), chamferRadius: u(0.15)), port(),
                          at: v3(centre, templeTop(at: 74 * k) - 0.1, -74 * k), euler: SCNVector3(slope, 0, 0)))
            let speaker = focusMarker(radius: 8)
            speaker.eulerAngles.x = .pi / 2
            speaker.position = v3(centre, templeBottom(at: grilleAt) - 0.8, -grilleAt)
            onTemple(speaker)
            // The near (left) one first: the camera frames it.
            if side > 0 { markers[.speakers, default: []].insert(speaker, at: 0) } else { mark(.speakers, speaker) }

            let insideFacing = SCNVector3(0, -side * .pi / 2, 0)
            if side < 0 {
                // The right temple: the capture button along its top, the power slider inside.
                onTemple(node(SCNBox(width: u(1.9), height: u(0.7), length: u(11 * k), chamferRadius: u(0.32)), silver(),
                              at: v3(centre, templeTop(at: 12 * k) + 0.15, -12 * k)))
                let button = focusMarker(radius: 7)
                button.eulerAngles.x = -.pi / 2
                button.position = v3(centre, templeTop(at: 12 * k) + 1.3, -12 * k)
                onTemple(button)
                mark(.captureButton, button)
                // The touchpad: the outer face behind the logo.
                onTemple(node(SCNPlane(width: u(36 * k), height: u(7.6 * k)), decal(touchpadImage, roughness: 0.3),
                              at: v3(centre + s * (sideThickness / 2 + 0.02), templeTop(at: 35 * k) - 5.6 * k, -35 * k),
                              euler: SCNVector3(0, side * .pi / 2, 0)))
                let pad = focusMarker(radius: 11)
                pad.eulerAngles.y = side * .pi / 2
                pad.position = v3(centre + s * (sideThickness / 2 + 0.8), templeTop(at: 33 * k) - 5.6 * k, -33 * k)
                onTemple(pad)
                mark(.touchpad, pad)
                onTemple(node(SCNBox(width: u(0.7), height: u(3.4 * k), length: u(10.5 * k), chamferRadius: u(0.32)),
                              gunmetal(), at: v3(-s * 0.2, mid, -10.3 * k)))
                onTemple(node(SCNCylinder(radius: u(0.45), height: u(0.3)),
                              pbr(UIColor(red: 0.85, green: 0.06, blue: 0.05, alpha: 1), roughness: 0.3, clearCoat: 1),
                              at: v3(-s * 0.6, mid, -6.6 * k), euler: SCNVector3(0, 0, Float.pi / 2)))
                onTemple(node(SCNPlane(width: u(34 * k), height: u(1.16 * k)), decal(modelLine),
                              at: v3(-s * 0.03, templeTop(at: 43 * k) - 3.0 * k, -43 * k), euler: insideFacing))
            } else {
                // The left temple: the Meta plate inside.
                onTemple(node(SCNBox(width: u(0.7), height: u(3.6 * k), length: u(9 * k), chamferRadius: u(0.35)), gunmetal(),
                              at: v3(-s * 0.2, mid, -9.5 * k)))
                onTemple(node(SCNPlane(width: u(5), height: u(2)), decal(metaMark),
                              at: v3(-s * 0.58, mid, -9.5 * k), euler: insideFacing))
            }
        }

        // Turn about the middle of the pair: front face to the temple tips, brow to the lowest
        // point of the front.
        let tipBack = frontFace - endDepth - curve(at: sideCentre).back - 131.2 * sideScale
        let frontLow = hingeTop - (hingeTop + 21.9 * frontRise) * cos(Self.lean)
        root.position = v3(0, -(24.5 * frontRise + frontLow) / 2, -(frontFace + tipBack) / 2)
        // Folded, the temples lie just behind the front: the pair is about 20 mm deep.
        let foldedCentre = v3(0, -(24.5 * frontRise + frontLow) / 2, -(frontFace + frontFace - endDepth - 9) / 2)

        let spinner = SCNNode()
        spinner.addChildNode(root)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, led: led.emitter ?? SCNNode(), ledGlow: glow, hinges: hinges,
                     markers: markers, root: root, openCentre: root.position, foldedCentre: foldedCentre)
    }

    // MARK: Scene

    /// One scene plus the nodes that animate. Held by MetaGlassesSceneView.
    final class Live: ModelStage {
        private let led: SCNNode
        private let ledGlow: SCNNode
        private let hinges: [(node: SCNNode, side: Float)]
        private let markers: [MetaGlassesPart: [SCNNode]]
        private let model: SCNNode
        private let centres: (open: SCNVector3, folded: SCNVector3)
        private let spinSeconds: Double
        /// The pose the turntable rests in, and returns to when a focus clears.
        private let idle: (spin: Float, tilt: Float)
        private var idleDistance: Float
        /// Whether the turntable should turn when nothing is focused.
        private var spinWanted: Bool
        private(set) var ledOn = false
        private(set) var folded = false
        private(set) var focus: MetaGlassesFocus?

        /// The listening blue, #3B82F6.
        static let listeningBlue = UIColor(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0, alpha: 1)

        /// A three-quarter pose by default, as the INMO card: the lenses turned to the right, the
        /// near (LED) temple running back.
        init(spin: Bool, tilt: Float = MetaGlassesModel.defaultTilt, cameraDistance: Float = MetaGlassesModel.cardDistance,
             spinSeconds: Double = 40, spinAngle: Float = 0.62, folded: Bool = false) {
            let parts = MetaGlassesModel.makeNode()
            led = parts.led
            ledGlow = parts.ledGlow
            hinges = parts.hinges
            markers = parts.markers
            model = parts.root
            centres = (parts.openCentre, parts.foldedCentre)
            self.spinSeconds = spinSeconds
            idle = (spinAngle, tilt)
            idleDistance = cameraDistance
            spinWanted = spin
            super.init(pivot: parts.pivot, spinner: parts.spinner, spin: spin, tilt: tilt, roll: 0,
                       cameraDistance: cameraDistance, spinSeconds: spinSeconds, spinAngle: spinAngle,
                       lights: ModelStage.studio(rim: SCNVector3(-0.9, 2.8, 0))
                           + [(.directional, 650, .white, SCNVector3(-0.35, Float.pi, 0))],  // a rim from behind
                       environment: 1.35)
            scene.lightingEnvironment.contents = MetaGlassesModel.studio
            // Close-ups bring the camera within a few centimetres of the frame.
            camera.camera?.zNear = 0.05
            camera.camera?.zFar = 40
            if folded { setFolded(true, animated: false) }
        }

        /// The capture LED: white and breathing while recording, dark otherwise. Not animated for a
        /// still, which draws one frame: it shows fully lit.
        func setLED(_ on: Bool, animated: Bool = true) {
            ledOn = on
            led.removeAction(forKey: "pulse")
            led.removeAction(forKey: "blink")
            guard on else {
                led.geometry?.firstMaterial?.emission.intensity = 0
                ledGlow.opacity = 0
                return
            }
            guard animated else {
                led.geometry?.firstMaterial?.emission.intensity = 2.2
                ledGlow.opacity = 1
                return
            }
            let period = 1.4
            let glow = ledGlow
            let pulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (1 - cos(Double(elapsed) / period * 2 * .pi)) / 2
                let level = CGFloat(0.5 + 0.5 * phase)
                node.geometry?.firstMaterial?.emission.intensity = 2.2 * level
                glow.opacity = level
            }
            led.runAction(.repeatForever(pulse), forKey: "pulse")
        }

        /// One blink of the LED, as for a photo, unless it is already lit.
        private func blinkLED(after delay: Double) {
            guard !ledOn else { return }
            let glow = ledGlow
            let blink = SCNAction.customAction(duration: 0.5) { node, elapsed in
                let level = CGFloat(sin(Double(elapsed) / 0.5 * .pi))
                node.geometry?.firstMaterial?.emission.intensity = 2 * level
                glow.opacity = level
            }
            led.runAction(.sequence([.wait(duration: delay), blink, .run { [weak self] node in
                guard self?.ledOn == false else { return }
                node.geometry?.firstMaterial?.emission.intensity = 0
                glow.opacity = 0
            }]), forKey: "blink")
        }

        /// Folds the temples in behind the front, or opens them.
        func setFolded(_ fold: Bool, animated: Bool = true) {
            folded = fold
            let centre = fold ? centres.folded : centres.open
            model.removeAction(forKey: "fold")
            if animated {
                let move = SCNAction.move(to: centre, duration: 0.6)
                move.timingMode = .easeInEaseOut
                model.runAction(move, forKey: "fold")
            } else {
                model.position = centre
            }
            for (hinge, side) in hinges {
                let angle = fold ? side * MetaGlassesModel.foldAngle(side) : 0
                hinge.removeAction(forKey: "fold")
                guard animated else {
                    hinge.eulerAngles.y = angle
                    continue
                }
                // The right temple folds a beat after the left, onto it, and opens first.
                let turn = SCNAction.rotateTo(x: 0, y: CGFloat(angle), z: 0, duration: 0.55, usesShortestUnitArc: true)
                turn.timingMode = .easeInEaseOut
                let delay = (side < 0) == fold ? 0.12 : 0
                hinge.runAction(.sequence([.wait(duration: delay), turn]), forKey: "fold")
            }
        }

        /// Starts or stops the slow turntable where it is. While a part is focused it only takes
        /// effect once the focus clears.
        func setSpinning(_ on: Bool) {
            spinWanted = on
            if on, focus == nil { startSpin() } else if !on { spinner.removeAction(forKey: "spin") }
        }

        private func startSpin() {
            guard spinner.action(forKey: "spin") == nil else { return }
            spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)), forKey: "spin")
        }

        /// The idle camera distance (the card's, or the closer hero's); a focused camera stays put.
        func setIdleDistance(_ distance: Float) {
            idleDistance = distance
            if focus == nil { camera.position.z = distance }
        }

        // MARK: Focus

        /// How each part is looked at: the turn and lean that present it, and how close the camera
        /// comes (at the 30° view, 1 unit shows 54 mm top to bottom).
        static func view(of part: MetaGlassesPart) -> (spin: Float, tilt: Float, distance: Float) {
            switch part {
            case .camera: return (-0.62, 0.15, 1.25)      // front three-quarter onto the left end piece
            case .led: return (0.62, 0.15, 1.25)          // the same onto the right end piece
            case .mic: return (0, -0.5, 3.1)              // straight on from below: bridge and hinge mics
            case .speakers: return (-1.2, -0.42, 2.6)     // the left temple from the side and below
            case .touchpad: return (1.32, 0.18, 1.7)      // the right temple's outer face
            case .captureButton: return (1.05, 0.85, 1.15) // down onto the right temple's top
            }
        }

        /// Glides the camera to a part and marks it, pausing the turntable; nil glides back to the
        /// resting pose and turns again if it should. Not animated for a still: the camera is placed
        /// and the marker shown at its brightest.
        func setFocus(_ focus: MetaGlassesFocus?, animated: Bool = true) {
            let previous = self.focus
            self.focus = focus
            hideMarkers()
            guard let focus else {
                glide(spin: idle.spin, tilt: idle.tilt, to: nil, distance: idleDistance, animated: animated) { [weak self] in
                    guard let self, self.focus == nil, self.spinWanted else { return }
                    self.startSpin()
                }
                return
            }
            spinner.removeAction(forKey: "spin")
            let view = Self.view(of: focus.part)
            glide(spin: view.spin, tilt: view.tilt, to: markers[focus.part]?.first, distance: view.distance,
                  animated: animated, completion: nil)
            // A one-off flash or ripple waits for the camera to land, so it is seen.
            show(focus, animated: animated, after: animated && previous?.part != focus.part ? 0.7 : 0)
        }

        /// Turns the pair to a pose and brings the camera square in front of target (or the middle).
        /// From wherever it is, so one focus glides straight on to the next.
        private func glide(spin: Float, tilt: Float, to target: SCNNode?, distance: Float, animated: Bool,
                           completion: (() -> Void)?) {
            // The turntable can leave the spinner's Euler angles flipped (x = z = π); restate the same
            // turn about Y alone, then take the short way round to the new one.
            let euler = spinner.eulerAngles
            if abs(euler.x) > 0.001 || abs(euler.z) > 0.001 {
                let q = spinner.orientation
                spinner.eulerAngles = SCNVector3(0, 2 * atan2(q.y, q.w), 0)
            }
            let current = spinner.eulerAngles.y
            let turn = remainderf(spin - current, 2 * .pi)

            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.8 : 0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if animated, let completion { SCNTransaction.completionBlock = completion }
            spinner.eulerAngles = SCNVector3(0, current + turn, 0)
            pivot.eulerAngles.x = tilt
            // Read through the new (model) pose: where the part will be once the glide lands.
            let centre = target?.convertPosition(SCNVector3Zero, to: nil) ?? SCNVector3Zero
            camera.position = SCNVector3(centre.x, centre.y, centre.z + distance)
            SCNTransaction.commit()
            if !animated { completion?() }
        }

        /// Puts every marker out (and lets a test compare a frame with and without one).
        func hideMarkers() {
            for marker in markers.values.joined() {
                marker.isHidden = true
                for child in marker.childNodes {
                    child.removeAction(forKey: "pulse")
                    child.opacity = 0
                    child.scale = SCNVector3(1, 1, 1)
                }
            }
        }

        /// The marker on the focused part: blue for the mics and speakers, white for the camera,
        /// LED and touch.
        private func show(_ focus: MetaGlassesFocus, animated: Bool, after delay: Double) {
            let tint: UIColor = (focus.pulse == .listening || focus.pulse == .speaking) ? Self.listeningBlue : .white
            for marker in markers[focus.part] ?? [] {
                marker.isHidden = false
                guard let glow = marker.childNode(withName: "glow", recursively: false) else { continue }
                let rings = (0..<3).compactMap { marker.childNode(withName: "ring\($0)", recursively: false) }
                for child in [glow] + rings { child.geometry?.firstMaterial?.multiply.contents = tint }
                if animated {
                    Self.animate(focus.pulse, glow: glow, rings: rings, after: delay)
                } else {
                    Self.hold(focus.pulse, glow: glow, rings: rings)
                }
            }
            if focus.pulse == .capture, animated { blinkLED(after: delay) }
        }

        /// A pulse frozen at its most legible moment, for a still.
        private static func hold(_ pulse: MetaGlassesPulse, glow: SCNNode, rings: [SCNNode]) {
            func set(_ node: SCNNode, _ opacity: CGFloat, _ scale: Float) {
                node.opacity = opacity
                node.scale = SCNVector3(scale, scale, scale)
            }
            switch pulse {
            case .listening: set(glow, 1, 1.1); set(rings[0], 0.7, 1)
            case .speaking: set(glow, 0.55, 0.9); set(rings[0], 0.95, 0.75); set(rings[1], 0.6, 1.25); set(rings[2], 0.3, 1.75)
            case .capture: set(glow, 1, 1.4); set(rings[0], 0.6, 1.3)
            case .recording: set(glow, 1, 1.15); set(rings[0], 0.45, 1)
            case .touch: set(glow, 0.6, 0.9); set(rings[0], 0.9, 1.2)
            }
        }

        private static func animate(_ pulse: MetaGlassesPulse, glow: SCNNode, rings: [SCNNode], after delay: Double) {
            let wait = SCNAction.wait(duration: delay)
            /// Opacity and scale breathing between two levels.
            func breathe(_ node: SCNNode, period: Double, opacity: ClosedRange<CGFloat>, scale: ClosedRange<Float>) {
                let breath = SCNAction.customAction(duration: period) { node, elapsed in
                    let phase = (1 - cos(Double(elapsed) / period * 2 * .pi)) / 2
                    node.opacity = opacity.lowerBound + (opacity.upperBound - opacity.lowerBound) * CGFloat(phase)
                    let s = scale.lowerBound + (scale.upperBound - scale.lowerBound) * Float(phase)
                    node.scale = SCNVector3(s, s, s)
                }
                node.runAction(.repeatForever(breath), forKey: "pulse")
            }
            /// One ring spreading out and fading.
            func ripple(_ duration: Double, from: Float, to: Float, opacity: CGFloat) -> SCNAction {
                SCNAction.customAction(duration: duration) { node, elapsed in
                    let t = Double(elapsed) / duration
                    let eased = Float(1 - pow(1 - t, 2.2))
                    let s = from + (to - from) * eased
                    node.scale = SCNVector3(s, s, s)
                    node.opacity = opacity * CGFloat(1 - t)
                }
            }
            switch pulse {
            case .listening:
                breathe(glow, period: 1.2, opacity: 0.35...1, scale: 0.85...1.2)
                breathe(rings[0], period: 1.2, opacity: 0.25...0.8, scale: 0.95...1.08)
            case .speaking:
                breathe(glow, period: 1.2, opacity: 0.25...0.6, scale: 0.8...1)
                for (index, ring) in rings.enumerated() {
                    let wave = SCNAction.repeatForever(ripple(1.2, from: 0.35, to: 2.0, opacity: 0.95))
                    ring.runAction(.sequence([.wait(duration: Double(index) * 0.4), wave]), forKey: "pulse")
                }
            case .capture:
                let flash = SCNAction.customAction(duration: 0.55) { node, elapsed in
                    let t = Double(elapsed) / 0.55
                    node.opacity = CGFloat(t < 0.1 ? t / 0.1 : 1 - (t - 0.1) / 0.9)
                    let s = Float(0.8 + 0.7 * t)
                    node.scale = SCNVector3(s, s, s)
                }
                glow.runAction(.sequence([wait, flash, .fadeOpacity(to: 0.3, duration: 0.3)]), forKey: "pulse")
                rings[0].runAction(.sequence([wait, ripple(0.6, from: 0.5, to: 1.8, opacity: 1),
                                              .fadeOpacity(to: 0.4, duration: 0.3)]), forKey: "pulse")
            case .recording:
                breathe(glow, period: 1.6, opacity: 0.45...1, scale: 0.95...1.15)
                breathe(rings[0], period: 1.6, opacity: 0.15...0.5, scale: 1...1)
            case .touch:
                let pop = SCNAction.customAction(duration: 0.4) { node, elapsed in
                    node.opacity = CGFloat(sin(Double(elapsed) / 0.4 * .pi)) * 0.9
                }
                glow.runAction(.sequence([wait, pop, .fadeOpacity(to: 0.25, duration: 0.25)]), forKey: "pulse")
                rings[0].runAction(.sequence([wait, ripple(0.55, from: 0.3, to: 1.7, opacity: 1),
                                              .fadeOpacity(to: 0.35, duration: 0.25)]), forKey: "pulse")
            }
        }
    }
}
