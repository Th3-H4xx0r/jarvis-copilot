import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The hand in the "put the ring on" sheet: a real hand model, posed.
///
/// The mesh is the WebXR generic hand (MIT, © 2019 Amazon — `RingHand-LICENSE.md`),
/// posed with the index finger out and the others folded by
/// `scripts/hand/bake_hand.py` and baked to `RingHand.bin`. The ring is put
/// into the same scene, so the depth buffer — not a painted overlay — decides
/// what is in front of the band and what is behind it.
///
/// Hand space is the ring's: one unit is the ring's outer radius, the ring's
/// seat on the index finger is the origin, the finger runs down +X and the
/// back of the hand faces +Y. The bake scales the hand so the finger's widest
/// point at the seat sits just inside the ring's bore.
enum RingHandModel {

    /// The baked hand.
    struct Mesh {
        let geometry: SCNGeometry
        /// The index fingertip, where the ring comes on from.
        let tip: SIMD3<Float>
    }

    /// Reads `RingHand.bin`: "JCHD", version, vertex and index counts, the
    /// fingertip, then positions, normals and 16-bit triangle indices.
    static func mesh(from data: Data) -> Mesh? {
        let bytes = [UInt8](data)
        guard bytes.count > 28, bytes[0..<4] == [0x4A, 0x43, 0x48, 0x44] else { return nil }
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        func f32(_ at: Int) -> Float { Float(bitPattern: UInt32(u32(at))) }
        guard u32(4) == 1 else { return nil }
        let vertices = u32(8), indices = u32(12)
        let tip = SIMD3(f32(16), f32(20), f32(24))
        let positionsAt = 28, normalsAt = positionsAt + vertices * 12, indicesAt = normalsAt + vertices * 12
        guard bytes.count >= indicesAt + indices * 2 else { return nil }

        func vectors(_ at: Int) -> [SCNVector3] {
            (0..<vertices).map { i in SCNVector3(f32(at + i * 12), f32(at + i * 12 + 4), f32(at + i * 12 + 8)) }
        }
        let triangles = (0..<indices).map { i in UInt16(bytes[indicesAt + i * 2]) | UInt16(bytes[indicesAt + i * 2 + 1]) << 8 }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vectors(positionsAt)), SCNGeometrySource(normals: vectors(normalsAt))],
            elements: [SCNGeometryElement(indices: triangles, primitiveType: .triangles)])
        return Mesh(geometry: geometry, tip: tip)
    }

    #if canImport(UIKit)
    /// The hand shipped with the app.
    static let bundled: Mesh? = Bundle.main.url(forResource: "RingHand", withExtension: "bin")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(mesh(from:))
    #endif

    /// The ring's size, from `RingModel`: kept here too so the harness, which
    /// cannot build the real ring, draws the same band.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.805
    static let bandWidth: CGFloat = 0.58

    /// Down the finger, pointing at the tip.
    static let fingerAxis = SIMD3<Float>(1, 0, 0)
    /// Where the ring closes around the finger.
    static let ringSeat = SIMD3<Float>(0, 0, 0)

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
    static func makeHand(_ mesh: Mesh) -> SCNNode {
        let geometry = mesh.geometry.copy() as? SCNGeometry ?? mesh.geometry
        geometry.materials = [skinMaterial()]
        return SCNNode(geometry: geometry)
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
        /// Where the ring waits before it comes in: past the fingertip, off the frame.
        private let ringEntry: SIMD3<Float>

        /// How the hand is held: palm down, tipped toward the camera so the back
        /// of the hand and all five fingers show.
        static let handEuler = SCNVector3(0.9, -0.35, 0.0)
        static let cameraAt = SCNVector3(0.9, -1.45, 18.5)

        /// - Parameter accent: the halo that marks where the ring goes.
        init(ring: SCNNode, hand mesh: Mesh, accent: CGColor,
             pose: SCNVector3 = Stage.handEuler, cameraAt: SCNVector3 = Stage.cameraAt) {
            ringEntry = mesh.tip + RingHandModel.fingerAxis * 7.5
            scene.background.contents = CGColor(gray: 0, alpha: 0)
            if let environment = RingHandModel.environment {
                scene.lightingEnvironment.contents = environment
                scene.lightingEnvironment.intensity = 1.1
            }

            hand.addChildNode(RingHandModel.makeHand(mesh))
            // Both belong to the hand, so they stay on the finger whichever way
            // the hand is held, and the finger hides the far side of each.
            let alongFinger = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: RingHandModel.fingerAxis)
            ringHolder.simdOrientation = alongFinger
            ringHolder.simdPosition = ringEntry
            ringHolder.addChildNode(ring)
            hand.addChildNode(ringHolder)

            halo.geometry = RingHandModel.halo(accent)
            halo.simdOrientation = alongFinger
            halo.simdPosition = RingHandModel.ringSeat
            halo.opacity = 0
            hand.addChildNode(halo)

            let root = SCNNode()
            root.eulerAngles = pose
            root.addChildNode(hand)
            scene.rootNode.addChildNode(root)

            for light in RingHandModel.lights() { scene.rootNode.addChildNode(light) }

            let lens = SCNCamera()
            lens.fieldOfView = 40
            lens.projectionDirection = .horizontal
            lens.zNear = 0.5
            lens.zFar = 200
            camera.camera = lens
            camera.position = cameraAt
            scene.rootNode.addChildNode(camera)
        }

        /// Holds one pose, for the render harness: on the finger, or waiting off
        /// the end of it with the halo showing where it will go.
        func pose(seated: Bool) {
            ringHolder.removeAllActions()
            halo.removeAllActions()
            ringHolder.opacity = 1
            ringHolder.simdPosition = seated ? RingHandModel.ringSeat : ringEntry
            halo.opacity = seated ? 0 : 0.85
        }

        /// The gesture, on a loop: the halo marks the place, the ring glides in
        /// from past the fingertip and settles into it, holds, and fades away to
        /// come round again. The hand never moves.
        func play() {
            ringHolder.removeAllActions()
            halo.removeAllActions()

            let entry = SCNVector3(ringEntry)
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
