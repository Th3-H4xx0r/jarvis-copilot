import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A hand, modelled rather than drawn.
///
/// The "put the ring on" sheet used to fake this with flat capsules and a slice
/// of finger painted back over the band. It never looked right, because the ring
/// was never actually on anything. Here the hand is real geometry — every bone a
/// tapered tube with a ball at each joint, the way a hand is actually jointed —
/// and the ring is put into the same scene, so the depth buffer decides what is
/// in front of what. The band passes through the finger because it passes
/// through the finger.
///
/// Space: +X runs out along the index finger, +Y is up, +Z is toward the camera.
/// One unit is the ring's outer radius, ~11.7 mm, so every measurement here is a
/// real hand's in disguise: the index finger is 17 mm across and 75 mm long.
enum RingHandModel {

    /// A joint: where the bone bends, and how thick the hand is there.
    struct Joint {
        var at: SIMD3<Float>
        var radius: CGFloat
        init(_ x: Float, _ y: Float, _ z: Float, _ r: CGFloat) {
            at = SIMD3(x, y, z)
            radius = r
        }
    }

    // MARK: The skeleton
    //
    // A relaxed right hand, palm down, fingers together and pointing right, seen
    // from above: the thumb is at the top and the index finger is the top finger,
    // so the ring goes on in clear space. Each finger is one ray from the wrist
    // through its knuckle to the tip, so the back of the hand and the finger are
    // one surface with no seam at the knuckle.
    //
    // Hand space here: +X down the fingers, +Y toward the thumb, +Z out of the
    // back of the hand.

    /// The index finger, held straight so the ring can travel its whole length.
    /// `index[1]` is the knuckle and `index[2]` the middle joint: the ring sits
    /// between them.
    static let index: [Joint] = [
        Joint(-5.40, -1.10, -0.50, 0.70),  // wrist
        Joint(0.00, 0.00, 0.00, 0.76),     // knuckle
        Joint(3.35, 0.12, 0.00, 0.66),     // middle joint
        Joint(5.50, 0.20, -0.02, 0.59),    // last joint
        Joint(7.05, 0.26, -0.06, 0.50),    // tip
    ]

    private static let middle: [Joint] = [
        Joint(-5.60, -2.00, -0.45, 0.70),
        Joint(-0.30, -1.95, 0.05, 0.76),
        Joint(3.25, -2.05, -0.05, 0.68),
        Joint(5.55, -2.10, -0.30, 0.60),
        Joint(7.20, -2.10, -0.70, 0.50),
    ]

    private static let thirdFinger: [Joint] = [
        Joint(-5.70, -2.90, -0.50, 0.68),
        Joint(-0.80, -3.80, -0.05, 0.72),
        Joint(2.40, -4.15, -0.20, 0.64),
        Joint(4.55, -4.35, -0.50, 0.56),
        Joint(6.05, -4.45, -0.90, 0.47),
    ]

    private static let littleFinger: [Joint] = [
        Joint(-5.70, -3.70, -0.60, 0.66),
        Joint(-1.60, -5.40, -0.25, 0.62),
        Joint(0.95, -6.00, -0.45, 0.55),
        Joint(2.55, -6.35, -0.75, 0.48),
        Joint(3.75, -6.60, -1.10, 0.41),
    ]

    /// The thumb, angled up and away from the index finger.
    private static let thumb: [Joint] = [
        Joint(-5.60, -1.05, -0.75, 0.96),
        Joint(-4.35, 0.20, -0.65, 0.92),
        Joint(-2.60, 1.60, -0.45, 0.75),
        Joint(-1.00, 2.50, -0.45, 0.64),
        Joint(0.35, 3.05, -0.60, 0.52),
    ]

    /// The forearm, which runs off the left of the frame. Flattened when it is
    /// placed: a wrist is wider than it is deep.
    private static let forearm: [Joint] = [
        Joint(-4.60, -2.40, -0.30, 2.05),
        Joint(-8.00, -2.60, -0.40, 1.80),
        Joint(-20.0, -3.10, -0.60, 2.10),
    ]

    // MARK: Where the ring goes

    /// The ring's size, from `RingModel`: kept here too so the harness, which
    /// cannot build the real ring, draws the same band.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.805
    static let bandWidth: CGFloat = 0.58

    /// A third of the way along the proximal phalanx — where a ring actually sits.
    private static let seatAlongBone: Float = 0.32

    /// Down the finger, pointing at the tip.
    static var fingerAxis: SIMD3<Float> {
        simd_normalize(index[2].at - index[1].at)
    }

    /// The point on the finger the ring closes around.
    static var ringSeat: SIMD3<Float> {
        index[1].at + (index[2].at - index[1].at) * seatAlongBone
    }

    /// Where the ring waits before it comes in: past the fingertip, off the frame.
    static var ringEntry: SIMD3<Float> {
        index[4].at + fingerAxis * 8.5
    }

    // MARK: Building

    /// One smooth tube through the joints: a Catmull-Rom curve for the bone, the
    /// radius eased between joints, and rounded ends swept from the same rings —
    /// so a finger is a single surface with no seams where parts used to meet.
    static func sweep(_ joints: [Joint], capStart: Bool = true, capEnd: Bool = true,
                      radial: Int = 40, perSegment: Int = 12) -> SCNGeometry {
        precondition(joints.count >= 2)
        let points = joints.map(\.at)
        let radii = joints.map { Float($0.radius) }

        func catmull(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
            0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
        }
        func catmull(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            SIMD3(catmull(a.x, b.x, c.x, d.x, t), catmull(a.y, b.y, c.y, d.y, t), catmull(a.z, b.z, c.z, d.z, t))
        }

        // Samples along the bone.
        var centres: [SIMD3<Float>] = []
        var widths: [Float] = []
        let last = points.count - 1
        for i in 0..<last {
            let a = i == 0 ? 2 * points[0] - points[1] : points[i - 1]
            let d = i + 2 > last ? 2 * points[last] - points[last - 1] : points[i + 2]
            let steps = i == last - 1 ? perSegment : perSegment - 1
            for k in 0...steps {
                let t = Float(k) / Float(perSegment)
                centres.append(catmull(a, points[i], points[i + 1], d, t))
                // Radius eases rather than overshoots: a spline on it would bulge.
                let e = t * t * (3 - 2 * t)
                widths.append(radii[i] + (radii[i + 1] - radii[i]) * e)
            }
        }

        // Tangents, and a frame carried down the curve without twisting.
        let n = centres.count
        var tangents: [SIMD3<Float>] = (0..<n).map { k in
            let ahead = centres[min(n - 1, k + 1)], behind = centres[max(0, k - 1)]
            return simd_normalize(ahead - behind)
        }
        tangents[0] = simd_normalize(centres[1] - centres[0])
        tangents[n - 1] = simd_normalize(centres[n - 1] - centres[n - 2])
        var normals: [SIMD3<Float>] = []
        var seed = simd_cross(tangents[0], SIMD3<Float>(0, 1, 0))
        if simd_length(seed) < 0.01 { seed = simd_cross(tangents[0], SIMD3<Float>(1, 0, 0)) }
        normals.append(simd_normalize(seed))
        for k in 1..<n {
            let turn = simd_quatf(from: tangents[k - 1], to: tangents[k])
            let carried = turn.act(normals[k - 1])
            normals.append(simd_normalize(carried - tangents[k] * simd_dot(carried, tangents[k])))
        }

        var positions: [SCNVector3] = []
        var shading: [SCNVector3] = []
        func ring(centre: SIMD3<Float>, radius: Float, tangent: SIMD3<Float>, normal: SIMD3<Float>,
                  lean: Float, bend: Float = 0) {
            let binormal = simd_cross(tangent, normal)
            for j in 0..<radial {
                let phi = 2 * Float.pi * Float(j) / Float(radial)
                let out = cos(phi) * normal + sin(phi) * binormal
                positions.append(SCNVector3(centre + out * radius))
                // `lean` tilts the normal for a tapering tube; `bend` rounds a cap.
                let surface = simd_normalize(out * cos(bend) + tangent * (sin(bend) - lean))
                shading.append(SCNVector3(surface))
            }
        }

        let capSteps = 8
        if capStart {
            for c in stride(from: capSteps, to: 0, by: -1) {
                let theta = Float.pi / 2 * Float(c) / Float(capSteps)
                ring(centre: centres[0] - tangents[0] * widths[0] * sin(theta),
                     radius: max(0.0001, widths[0] * cos(theta)),
                     tangent: tangents[0], normal: normals[0], lean: 0, bend: -theta)
            }
        }
        for k in 0..<n {
            let ahead = min(n - 1, k + 1), behind = max(0, k - 1)
            let run = simd_length(centres[ahead] - centres[behind])
            let lean = run > 0 ? (widths[ahead] - widths[behind]) / run : 0
            ring(centre: centres[k], radius: widths[k], tangent: tangents[k], normal: normals[k], lean: lean)
        }
        if capEnd {
            for c in 1...capSteps {
                let theta = Float.pi / 2 * Float(c) / Float(capSteps)
                ring(centre: centres[n - 1] + tangents[n - 1] * widths[n - 1] * sin(theta),
                     radius: max(0.0001, widths[n - 1] * cos(theta)),
                     tangent: tangents[n - 1], normal: normals[n - 1], lean: 0, bend: theta)
            }
        }

        let rings = positions.count / radial
        var indices: [Int32] = []
        indices.reserveCapacity((rings - 1) * radial * 6)
        for r in 0..<(rings - 1) {
            let a = r * radial, b = (r + 1) * radial
            for j in 0..<radial {
                let j2 = (j + 1) % radial
                indices += [Int32(a + j), Int32(a + j2), Int32(b + j),
                            Int32(a + j2), Int32(b + j2), Int32(b + j)]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: shading)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// A finger is a touch narrower between its joints than across them. Adds
    /// that waist midway along each bone past the knuckle, on the straight line
    /// between the joints, so the ring's path down the index stays true.
    private static func waisted(_ joints: [Joint]) -> [Joint] {
        guard joints.count > 2 else { return joints }
        var out = [joints[0], joints[1]]
        for (a, b) in zip(joints.dropFirst(), joints.dropFirst(2)) {
            let middle = (a.at + b.at) / 2
            out.append(Joint(middle.x, middle.y, middle.z, (a.radius + b.radius) / 2 * 0.97))
            out.append(b)
        }
        return out
    }

    /// A white studio model: matte, with just enough sheen to pick up the key
    /// light along the top of the finger.
    static func skinMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        #if canImport(UIKit)
        m.diffuse.contents = UIColor(white: 0.86, alpha: 1)
        #else
        m.diffuse.contents = NSColor(white: 0.86, alpha: 1)
        #endif
        m.metalness.contents = 0.0
        m.roughness.contents = 0.58
        m.clearCoat.contents = 0.22
        m.clearCoatRoughness.contents = 0.6
        return m
    }

    /// The whole hand, in hand space.
    static func makeHand() -> SCNNode {
        let material = skinMaterial()
        let hand = SCNNode()
        for finger in [index, middle, thirdFinger, littleFinger] {
            let geometry = sweep(waisted(finger))
            geometry.materials = [material]
            hand.addChildNode(SCNNode(geometry: geometry))
        }
        // The thumb takes the key light at a grazing angle, where a waist shows
        // as ripples rather than joints: it stays a plain taper.
        let thumbGeometry = sweep(thumb)
        thumbGeometry.materials = [material]
        hand.addChildNode(SCNNode(geometry: thumbGeometry))
        let arm = sweep(forearm, capEnd: false)
        arm.materials = [material]
        let armNode = SCNNode(geometry: arm)
        armNode.simdScale = SIMD3(1, 1, 0.62)
        hand.addChildNode(armNode)

        // The back of the hand: a flattened mass under the metacarpals, so it is
        // one surface with the knuckles standing just proud of it.
        let palm = SCNSphere(radius: 1)
        palm.segmentCount = 48
        palm.materials = [material]
        let palmNode = SCNNode(geometry: palm)
        palmNode.simdPosition = SIMD3(-3.35, -2.60, -0.25)
        palmNode.simdScale = SIMD3(2.85, 3.15, 1.12)
        hand.addChildNode(palmNode)

        // The fleshy pad at the base of the thumb.
        let pad = SCNSphere(radius: 1)
        pad.segmentCount = 40
        pad.materials = [material]
        let padNode = SCNNode(geometry: pad)
        padNode.simdPosition = SIMD3(-3.95, 0.05, -0.55)
        padNode.eulerAngles = SCNVector3(0, 0, 0.70)
        padNode.simdScale = SIMD3(1.75, 1.05, 0.95)
        hand.addChildNode(padNode)
        return hand
    }

    // MARK: The stage

    /// The hand, the ring and the light on them.
    ///
    /// The ring is passed in rather than built here: the app hands over the real
    /// `RingModel`, and the render harness hands over a plain band. Either way it
    /// must be a node whose own axis is +Y and which is centred on its middle —
    /// the stage turns it to lie along the finger.
    final class Stage {
        let scene = SCNScene()
        let camera = SCNNode()
        private let ringHolder = SCNNode()
        private let halo = SCNNode()
        private let hand = SCNNode()

        /// How the hand is held: palm down, tipped toward the camera so the back
        /// of the hand and all five fingers show.
        static let handEuler = SCNVector3(0.62, 0.0, 0.0)

        /// - Parameter accent: the halo that marks where the ring goes.
        init(ring: SCNNode, accent: CGColor) {
            scene.background.contents = CGColor(gray: 0, alpha: 0)
            if let environment = RingHandModel.environment {
                scene.lightingEnvironment.contents = environment
                scene.lightingEnvironment.intensity = 1.1
            }

            hand.addChildNode(RingHandModel.makeHand())
            // Both belong to the hand, so they stay on the finger whichever way
            // the hand is held, and the finger hides the far side of each.
            let alongFinger = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: RingHandModel.fingerAxis)
            ringHolder.simdOrientation = alongFinger
            ringHolder.simdPosition = RingHandModel.ringEntry
            ringHolder.addChildNode(ring)
            hand.addChildNode(ringHolder)

            halo.geometry = RingHandModel.halo(accent)
            halo.simdOrientation = alongFinger
            halo.simdPosition = RingHandModel.ringSeat
            halo.opacity = 0
            hand.addChildNode(halo)

            let root = SCNNode()
            root.eulerAngles = Stage.handEuler
            root.addChildNode(hand)
            scene.rootNode.addChildNode(root)

            for light in RingHandModel.lights() { scene.rootNode.addChildNode(light) }

            let lens = SCNCamera()
            lens.fieldOfView = 40
            lens.projectionDirection = .horizontal
            lens.zNear = 0.5
            lens.zFar = 200
            camera.camera = lens
            camera.position = SCNVector3(0.55, -1.05, 29.5)
            scene.rootNode.addChildNode(camera)
        }

        /// Holds one pose, for the render harness: on the finger, or waiting off
        /// the end of it with the halo showing where it will go.
        func pose(seated: Bool) {
            ringHolder.removeAllActions()
            halo.removeAllActions()
            ringHolder.opacity = 1
            ringHolder.simdPosition = seated ? RingHandModel.ringSeat : RingHandModel.ringEntry
            halo.opacity = seated ? 0 : 0.85
        }

        /// The gesture, on a loop: the halo marks the place, the ring glides in
        /// from past the fingertip and settles into it, holds, and fades away to
        /// come round again. The hand never moves.
        func play() {
            ringHolder.removeAllActions()
            halo.removeAllActions()

            let entry = SCNVector3(RingHandModel.ringEntry)
            let seat = SCNVector3(RingHandModel.ringSeat)
            let glide = SCNAction.move(to: seat, duration: 1.15)
            glide.timingMode = .easeInEaseOut
            let ring = SCNAction.sequence([
                .run { node in node.position = entry; node.opacity = 0 },
                .wait(duration: 0.55),
                .group([.fadeIn(duration: 0.3), glide]),
                .wait(duration: 1.7),
                .fadeOut(duration: 0.4),
                .wait(duration: 0.25),
            ])
            ringHolder.runAction(.repeatForever(ring), forKey: "gesture")

            // The halo breathes while the finger is bare and goes out as the ring
            // arrives: 0.55 s of hint, then it fades under the ring's glide.
            let halo = SCNAction.sequence([
                .run { node in node.opacity = 0 },
                .fadeOpacity(to: 0.85, duration: 0.35),
                .fadeOpacity(to: 0.45, duration: 0.45),
                .fadeOut(duration: 0.55),
                .wait(duration: 3.0),
            ])
            self.halo.runAction(.repeatForever(halo), forKey: "gesture")
        }
    }

    /// A ghost of the ring in the accent colour, sitting where the ring will
    /// go. Seen almost edge-on, a thin line of light vanished against the white
    /// finger; a translucent band the ring's own size reads as "here".
    private static func halo(_ accent: CGColor) -> SCNGeometry {
        let band = SCNTube(innerRadius: innerRadius, outerRadius: outerRadius, height: bandWidth)
        band.radialSegmentCount = 72
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = accent
        m.transparency = 0.6
        m.writesToDepthBuffer = false
        band.materials = [m]
        return band
    }

    // MARK: Light

    private static func lights() -> [SCNNode] {
        let placements: [(SCNLight.LightType, CGFloat, SIMD3<Float>, SCNVector3)] = [
            // Key, high and to the left, so the top of the finger catches it.
            (.directional, 780, SIMD3(1, 1, 1), SCNVector3(-0.55, 0.50, 0)),
            // Cool fill from below the hand, which keeps the underside from going flat black.
            (.directional, 300, SIMD3(0.72, 0.82, 1.0), SCNVector3(0.75, -0.35, 0)),
            // A rim from behind the right, to draw the fingertip out of the sheet.
            (.directional, 420, SIMD3(1, 0.97, 0.94), SCNVector3(0.1, 2.45, 0)),
            (.ambient, 70, SIMD3(1, 1, 1), SCNVector3Zero),
        ]
        return placements.map { type, intensity, rgb, euler in
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            #if canImport(UIKit)
            light.color = UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            #else
            light.color = NSColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            #endif
            let node = SCNNode()
            node.light = light
            node.eulerAngles = euler
            return node
        }
    }

    /// A plain studio gradient for the skin to reflect. Drawn with Core Graphics
    /// so the same code builds it on the phone and in the render harness.
    private static let environment: CGImage? = {
        let width = 256, height = 128
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 0.92, alpha: 1), CGColor(gray: 0.30, alpha: 1), CGColor(gray: 0.04, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            // Core Graphics counts up from the bottom: light at the top of the image is light from above.
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: 44, y: 84, width: 40, height: 30))
        return context.makeImage()
    }()
}
