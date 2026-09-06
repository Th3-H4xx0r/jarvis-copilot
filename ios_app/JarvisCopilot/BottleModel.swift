import SceneKit

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

/// A procedural model of the VSITOO S1 Pro, built as a surface of revolution.
///
/// The silhouette is traced from a reference photo of the bottle: 728 px tall with a
/// 190 px body diameter, so the body radius is 95/728 ≈ 0.1305 when the bottle is one
/// unit tall. Everything below is expressed in those two units — height 0…1 from the
/// base, and radius in multiples of the body radius.
enum BottleModel {

    static let bodyRadius: CGFloat = 0.1305
    private static let capRadius: CGFloat = 0.665      // measured 126/190 of body width

    // Key heights along the silhouette.
    private static let yBaseFillet: CGFloat = 0.024
    private static let yBodyTop: CGFloat    = 0.630
    private static let yNeck: CGFloat       = 0.845
    static let ySeam: CGFloat               = 0.862    // where the lid parts from the body
    private static let yCapTop: CGFloat     = 0.978
    private static let yTopEdge: CGFloat    = 0.992

    /// How far the lid rises when it unscrews.
    static let capLift: CGFloat = 0.20

    /// Radius (in body-radius units) at a given normalised height.
    private static func radius(at y: CGFloat) -> CGFloat {
        switch y {
        case ..<yBaseFillet:
            // Rounded base edge: a quarter circle up to the full body width.
            let u = y / yBaseFillet
            return sqrt(max(0, 1 - (1 - u) * (1 - u))) * 0.995

        case ..<yBodyTop:
            // Very slightly barrelled — narrows a touch toward the shoulder.
            let u = (y - yBaseFillet) / (yBodyTop - yBaseFillet)
            return 1.0 - 0.025 * u * u

        case ..<yNeck:
            // Shoulder: an S-curve in to the neck, like a decanter.
            let u = (y - yBodyTop) / (yNeck - yBodyTop)
            let s = u * u * (3 - 2 * u)                 // smoothstep
            return 0.975 + (capRadius * 0.975 - 0.975) * s

        case ..<ySeam:
            // Narrow seam where the lid meets the body.
            return capRadius * 0.965

        case ..<yCapTop:
            return capRadius

        case ..<yTopEdge:
            // Rounded top edge of the lid.
            let u = (y - yCapTop) / (yTopEdge - yCapTop)
            return capRadius * (1 - 0.12 * u * u)

        default:
            // Flat top face.
            let u = min(1, (y - yTopEdge) / 0.006)
            return capRadius * 0.88 * sqrt(max(0, 1 - u * u))
        }
    }

    /// Samples the profile between two heights, in scene units.
    private static func profile(from lo: CGFloat, to hi: CGFloat,
                                rings: Int) -> [(y: CGFloat, r: CGFloat)] {
        (0...rings).map { i in
            let y = lo + (hi - lo) * CGFloat(i) / CGFloat(rings)
            return (y, radius(at: y) * bodyRadius)
        }
    }

    // MARK: Geometry

    /// Lathes a profile into a smooth-shaded mesh.
    private static func lathe(_ pts: [(y: CGFloat, r: CGFloat)],
                              segments: Int = 48) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []

        // 2D profile normal at each ring, from the tangent between neighbours.
        var profileNormals: [(CGFloat, CGFloat)] = []
        for i in pts.indices {
            let prev = pts[max(0, i - 1)], next = pts[min(pts.count - 1, i + 1)]
            let dy = next.y - prev.y, dr = next.r - prev.r
            let len = max(1e-6, sqrt(dy * dy + dr * dr))
            profileNormals.append((dy / len, -dr / len))   // (radial, axial)
        }

        for (i, p) in pts.enumerated() {
            let n = profileNormals[i]
            for s in 0...segments {
                let a = 2 * CGFloat.pi * CGFloat(s) / CGFloat(segments)
                let ca = cos(a), sa = sin(a)
                positions.append(SCNVector3(Float(p.r * ca), Float(p.y), Float(p.r * sa)))
                normals.append(SCNVector3(Float(n.0 * ca), Float(n.1), Float(n.0 * sa)))
                uvs.append(CGPoint(x: CGFloat(s) / CGFloat(segments), y: 1 - p.y))
            }
        }

        var indices: [Int32] = []
        let stride = segments + 1
        for i in 0..<(pts.count - 1) {
            for s in 0..<segments {
                let a = Int32(i * stride + s)
                let b = Int32(i * stride + s + 1)
                let c = Int32((i + 1) * stride + s)
                let d = Int32((i + 1) * stride + s + 1)
                indices += [a, c, b, b, c, d]
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Sweeps a circular cross-section along a closed planar path in XY.
    private static func sweepTube(path: [(x: CGFloat, y: CGFloat)],
                                  radius: CGFloat,
                                  tubeSegments: Int = 10) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        let n = path.count

        for i in 0..<n {
            let prev = path[(i - 1 + n) % n], next = path[(i + 1) % n]
            let tx = next.x - prev.x, ty = next.y - prev.y
            let tl = max(1e-6, sqrt(tx * tx + ty * ty))
            // In-plane normal, and the out-of-plane axis, form the cross-section basis.
            let ax = -ty / tl, ay = tx / tl
            for j in 0...tubeSegments {
                let a = 2 * CGFloat.pi * CGFloat(j) / CGFloat(tubeSegments)
                let c = cos(a), sn = sin(a)
                let nx = ax * c, ny = ay * c, nz = sn
                positions.append(SCNVector3(Float(path[i].x + radius * nx),
                                            Float(path[i].y + radius * ny),
                                            Float(radius * nz)))
                normals.append(SCNVector3(Float(nx), Float(ny), Float(nz)))
                uvs.append(CGPoint(x: CGFloat(i) / CGFloat(n),
                                   y: CGFloat(j) / CGFloat(tubeSegments)))
            }
        }

        var indices: [Int32] = []
        let stride = tubeSegments + 1
        for i in 0..<n {
            let i2 = (i + 1) % n
            for j in 0..<tubeSegments {
                let a = Int32(i * stride + j)
                let b = Int32(i * stride + j + 1)
                let c = Int32(i2 * stride + j)
                let d = Int32(i2 * stride + j + 1)
                indices += [a, c, b, b, c, d]
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs),
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// The carry strap. The close-up shows a narrow lanyard anchored at the lid's top
    /// rim: two near-parallel strands hanging down with rounded ends, not a wide ring.
    /// So the path is a stadium — straight sides, semicircular caps — not an ellipse.
    static let loopGeometry: SCNGeometry = {
        let w: CGFloat = 0.0135                 // half the gap between the two strands
        let b: CGFloat = 0.086                  // half-height
        let straight = b - w
        let sideSteps = 16, capSteps = 10
        var path: [(x: CGFloat, y: CGFloat)] = []

        for i in 0..<sideSteps {                                  // down the right strand
            let t = CGFloat(i) / CGFloat(sideSteps)
            path.append((w, straight - 2 * straight * t))
        }
        for i in 0...capSteps {                                   // round the bottom
            let a = CGFloat.pi * CGFloat(i) / CGFloat(capSteps)
            path.append((w * cos(a), -straight - w * sin(a)))
        }
        for i in 0..<sideSteps {                                  // up the left strand
            let t = CGFloat(i) / CGFloat(sideSteps)
            path.append((-w, -straight + 2 * straight * t))
        }
        for i in 0...capSteps {                                   // round the top
            let a = CGFloat.pi * CGFloat(i) / CGFloat(capSteps)
            path.append((-w * cos(a), straight + w * sin(a)))
        }
        return sweepTube(path: path, radius: 0.0052)
    }()

    /// The UV shaft: an open cone widening downward from the lamp into the bottle mouth.
    static let beamGeometry: SCNGeometry = {
        let rTop = bodyRadius * capRadius * 0.34
        let rBot = bodyRadius * capRadius * 0.82
        let pts = (0...8).map { i -> (y: CGFloat, r: CGFloat) in
            let u = CGFloat(i) / 8
            return (capLift * u, rBot + (rTop - rBot) * u)
        }
        return lathe(pts, segments: 48)
    }()

    // Body and lid are separate meshes so the lid can unscrew. Each is closed off at the
    // seam with a disc (radius → 0) so you don't see through the parted surfaces.
    // Built once and shared; scenes take `.copy()` so they get their own materials.
    static let bodyGeometry: SCNGeometry = lathe(profile(from: 0, to: ySeam, rings: 110))
    static let capGeometry: SCNGeometry = lathe(profile(from: ySeam, to: 1.0, rings: 36))

    /// A flat disc at y = 0, normal up or down, used to close the parted surfaces.
    private static func disc(radius r: CGFloat, facingUp: Bool) -> SCNGeometry {
        let pts: [(y: CGFloat, r: CGFloat)] = facingUp ? [(0, r), (0, 0)] : [(0, 0), (0, r)]
        return lathe(pts, segments: 48)
    }

    /// Near-black and fully rough, so it reads as an opening rather than a lit surface.
    private static func voidMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = PlatformColor(white: 0.02, alpha: 1)
        m.roughness.contents = 1.0
        m.metalness.contents = 0.0
        return m
    }

    private static func matteBlack() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        // Not pure black: the real bottle is matte, but a true 0.0 albedo reads as a
        // silhouette with no form at icon size.
        m.diffuse.contents = PlatformColor(white: 0.085, alpha: 1)
        m.roughness.contents = 0.58
        m.metalness.contents = 0.0
        m.isDoubleSided = false
        return m
    }

    /// Additive, unlit, depth-transparent — so it reads as light rather than plastic.
    private static func uvGlow() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = PlatformColor.black
        m.emission.contents = PlatformColor(red: 0.62, green: 0.34, blue: 1.0, alpha: 1)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        return m
    }

    // MARK: Assembled node

    struct Parts {
        /// Outermost: scale, opacity and the left-right tilt.
        let pivot: SCNNode
        /// Inside the tilt: the turntable rotation.
        let spinner: SCNNode
        let cap: SCNNode
        let beam: SCNNode
    }

    /// The bottle, centred on the origin and one unit tall.
    static func makeNode() -> Parts {
        let root = SCNNode()

        let bodyGeo = bodyGeometry.copy() as! SCNGeometry
        let bodyMaterial = matteBlack()
        bodyGeo.materials = [bodyMaterial]
        root.addChildNode(SCNNode(geometry: bodyGeo))

        let mouth = disc(radius: radius(at: ySeam) * bodyRadius, facingUp: true)
        mouth.materials = [voidMaterial()]
        let mouthNode = SCNNode(geometry: mouth)
        mouthNode.position = SCNVector3(0, Float(ySeam), 0)
        root.addChildNode(mouthNode)

        // Lid, as its own node so it can lift and spin off.
        let capGeo = capGeometry.copy() as! SCNGeometry
        capGeo.materials = [matteBlack()]
        let cap = SCNNode(geometry: capGeo)

        let underside = disc(radius: radius(at: ySeam) * bodyRadius, facingUp: false)
        underside.materials = [voidMaterial()]
        let undersideNode = SCNNode(geometry: underside)
        undersideNode.position = SCNVector3(0, Float(ySeam), 0)
        cap.addChildNode(undersideNode)

        // Lighter seam line where the lid meets the neck — travels with the lid.
        let seam = SCNTorus(ringRadius: bodyRadius * capRadius * 0.955,
                            pipeRadius: bodyRadius * 0.010)
        let seamMat = SCNMaterial()
        seamMat.lightingModel = .physicallyBased
        seamMat.diffuse.contents = PlatformColor(white: 0.035, alpha: 1)
        seamMat.roughness.contents = 0.85
        seam.materials = [seamMat]
        let seamNode = SCNNode(geometry: seam)
        seamNode.position = SCNVector3(0, Float(ySeam), 0)
        cap.addChildNode(seamNode)

        // The silicone carry loop on the lid, protruding from one side.
        let loopGeo = loopGeometry.copy() as! SCNGeometry
        let loopMat = SCNMaterial()
        loopMat.lightingModel = .physicallyBased
        loopMat.diffuse.contents = PlatformColor(white: 0.05, alpha: 1)
        loopMat.roughness.contents = 0.85
        loopGeo.materials = [loopMat]
        let loopNode = SCNNode(geometry: loopGeo)
        loopNode.eulerAngles = SCNVector3(0, 0, Float(0.20))   // free end swings out
        loopNode.position = SCNVector3(Float(bodyRadius * capRadius + 0.004),
                                       Float(0.888), 0)
        cap.addChildNode(loopNode)
        root.addChildNode(cap)

        // UV beam: a shaft of light spanning the gap the lid leaves behind, plus a
        // brighter pool at the bottle mouth. Hidden until a cycle runs.
        let beam = SCNNode()
        beam.name = "beam"
        let shaftGeo = beamGeometry.copy() as! SCNGeometry
        shaftGeo.materials = [uvGlow()]
        let shaftNode = SCNNode(geometry: shaftGeo)
        shaftNode.position = SCNVector3(0, Float(ySeam), 0)
        shaftNode.opacity = 0.30
        beam.addChildNode(shaftNode)

        let lamp = SCNLight()
        lamp.type = .omni
        lamp.color = PlatformColor(red: 0.62, green: 0.34, blue: 1.0, alpha: 1)
        lamp.intensity = 0
        lamp.attenuationStartDistance = 0.0
        lamp.attenuationEndDistance = 0.65
        lamp.attenuationFalloffExponent = 1.0
        let lampNode = SCNNode()
        lampNode.name = "uvLamp"
        lampNode.light = lamp
        lampNode.position = SCNVector3(0, Float(ySeam + capLift * 0.45), 0)
        beam.addChildNode(lampNode)

        beam.opacity = 0
        beam.isHidden = true
        root.addChildNode(beam)

        // Sit the model on the origin so it rotates about its own centre.
        root.position = SCNVector3(0, -0.5, 0)
        let spinner = SCNNode()
        spinner.addChildNode(root)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, cap: cap, beam: beam)
    }

    // MARK: Scene

    /// One scene plus the nodes that get animated. Held by the SwiftUI view.
    final class Live {
        let scene = SCNScene()
        let pivot: SCNNode
        let spinner: SCNNode
        let camera: SCNNode
        private let cap: SCNNode
        private let beam: SCNNode
        private let lamp: SCNNode?
        private let spins: Bool
        /// The pose this scene was built in; stopping a cycle animates back to it.
        private var homeCamera = Live.restCamera
        private var homeTilt: CGFloat = 0

        static let restCamera = SCNVector3(0, 0.04, 3.1)
        /// Framed on the lid once the bottle is tilted: the seam lands near (0.26, 0.26)
        /// and the unscrewed lid rides out to roughly (0.45, 0.45).
        static let capCamera  = SCNVector3(0.34, 0.30, 1.78)
        /// A 45° lean, top to the right, so the base runs off the bottom-left.
        static let tiltAngle: CGFloat = -.pi / 4
        /// Scales every beat of the sterilise sequence. 0.50 == half the original
        /// timing.
        static let pace: TimeInterval = 0.50

        /// `tilt` leans the bottle for a static card pose; `cameraX` slides the framing
        /// so it can sit off-centre and bleed past an edge.
        init(spin: Bool, tilt: CGFloat = 0,
             cameraX: Float = 0, cameraY: Float = .nan, cameraZ: Float = 0) {
            spins = spin
            let parts = BottleModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            cap = parts.cap
            beam = parts.beam
            lamp = parts.beam.childNode(withName: "uvLamp", recursively: true)

            scene.background.contents = PlatformColor.clear
            scene.rootNode.addChildNode(pivot)
            if spin {
                spinner.runAction(.repeatForever(
                    .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)), forKey: "spin")
            } else {
                spinner.eulerAngles = SCNVector3(0, Float(-0.5), 0)
            }

            // Three-point lighting: matte black needs rim light to show its silhouette.
            func light(_ intensity: CGFloat, _ color: PlatformColor,
                       _ euler: SCNVector3) -> SCNNode {
                let l = SCNLight()
                l.type = .directional
                l.intensity = intensity
                l.color = color
                let n = SCNNode()
                n.light = l
                n.eulerAngles = euler
                return n
            }
            scene.rootNode.addChildNode(light(900, .white, SCNVector3(-0.5, 0.7, 0)))
            scene.rootNode.addChildNode(
                light(320, PlatformColor(red: 0.75, green: 0.83, blue: 1, alpha: 1),
                      SCNVector3(-0.2, -1.1, 0)))
            scene.rootNode.addChildNode(
                light(700, PlatformColor(red: 0.6, green: 0.78, blue: 1, alpha: 1),
                      SCNVector3(0.35, 2.5, 0)))
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 130
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            let cam = SCNCamera()
            cam.fieldOfView = 22
            camera = SCNNode()
            camera.name = "camera"
            camera.camera = cam
            // SCNVector3 takes CGFloat on macOS and Float on iOS, so normalise both.
            camera.position = SCNVector3(cameraX,
                                         cameraY.isNaN ? Float(Live.restCamera.y) : cameraY,
                                         cameraZ == 0 ? Float(Live.restCamera.z) : cameraZ)
            scene.rootNode.addChildNode(camera)
            if tilt != 0 { pivot.eulerAngles = SCNVector3(0, 0, Float(tilt)) }
            homeCamera = camera.position
            homeTilt = tilt
        }

        /// Scales and settles the bottle into place — used when the info screen opens.
        func playEntrance() {
            pivot.scale = SCNVector3(0.55, 0.55, 0.55)
            pivot.opacity = 0
            spinner.eulerAngles = SCNVector3(0, Float(-1.35), 0)
            let grow = SCNAction.scale(to: 1.0, duration: 0.55)
            grow.timingMode = .easeOut
            pivot.runAction(.group([grow, .fadeIn(duration: 0.35)]))

            let settle = SCNAction.rotateTo(x: 0, y: -0.5, z: 0,
                                            duration: 0.7, usesShortestUnitArc: true)
            settle.timingMode = .easeOut
            spinner.runAction(settle) { [weak self] in
                guard let self, self.spins else { return }
                self.spinner.runAction(.repeatForever(
                    .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)), forKey: "spin")
            }
        }

        /// Leans the bottle to 45° while it spins, cranes up to the lid as the body runs
        /// off frame, unscrews the lid and pulses a UV beam out of the opening.
        /// Stopping unwinds the same beats in reverse.
        ///
        /// Everything is driven by SCNActions rather than SCNTransaction so the whole
        /// sequence advances on scene time and can be stepped through offscreen.
        func setSterilising(_ on: Bool) {
            cap.removeAllActions()
            beam.removeAllActions()
            camera.removeAllActions()
            lamp?.removeAllActions()
            pivot.removeAction(forKey: "tilt")

            let p = Live.pace

            guard on else {
                // Unwind in the reverse order it played, at the same pace, rather than
                // snapping every node back at once.
                let dim = SCNAction.customAction(duration: 0.5 * p) { node, elapsed in
                    let t = Double(elapsed) / (0.5 * p)
                    node.light?.intensity = CGFloat(14 * max(0, 1 - t))
                }
                lamp?.runAction(dim)

                beam.runAction(.sequence([.fadeOut(duration: 0.5 * p), .hide()]))

                let lower = SCNAction.move(to: SCNVector3Zero, duration: 1.1 * p)
                lower.timingMode = .easeInEaseOut
                let untwist = SCNAction.rotateBy(x: 0, y: -.pi * 4, z: 0, duration: 1.1 * p)
                untwist.timingMode = .easeInEaseOut
                cap.runAction(.sequence([
                    .wait(duration: 0.30 * p),
                    .group([lower, untwist]),
                ]))

                let craneBack = SCNAction.move(to: homeCamera, duration: 1.15 * p)
                craneBack.timingMode = .easeInEaseOut
                camera.runAction(.sequence([.wait(duration: 1.00 * p), craneBack]))

                let level = SCNAction.rotateTo(x: 0, y: 0, z: homeTilt,
                                               duration: 1.35 * p,
                                               usesShortestUnitArc: true)
                level.timingMode = .easeInEaseOut
                pivot.runAction(.sequence([.wait(duration: 1.20 * p), level]), forKey: "tilt")
                return
            }

            // 1. One continuous lean to 45°, top to the right, so the base runs off the
            //    bottom-left.
            let lean = SCNAction.rotateTo(x: 0, y: 0, z: Live.tiltAngle,
                                          duration: 1.35 * p, usesShortestUnitArc: true)
            lean.timingMode = .easeInEaseOut
            pivot.runAction(lean, forKey: "tilt")

            // The idle turntable is one revolution per 12s — barely 40° across the lean.
            // Spin a turn and a half over the same beat so the two moves read as one.
            spinner.removeAction(forKey: "spin")
            let whip = SCNAction.rotateBy(x: 0, y: .pi * 3, z: 0, duration: 1.35 * p)
            whip.timingMode = .easeInEaseOut
            spinner.runAction(.sequence([
                whip,
                .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)),
            ]), forKey: "spin")

            // 2. Crane after the lean, following the lid up and to the right.
            let craneUp = SCNAction.move(to: Live.capCamera, duration: 1.30 * p)
            craneUp.timingMode = .easeInEaseOut
            camera.runAction(.sequence([.wait(duration: 0.30 * p), craneUp]))

            // 3. Once the lid is framed, unscrew it and leave it hovering.
            let lift = SCNAction.move(to: SCNVector3(0, Float(BottleModel.capLift), 0),
                                      duration: 1.1 * p)
            lift.timingMode = .easeOut
            let twist = SCNAction.rotateBy(x: 0, y: .pi * 4, z: 0, duration: 1.1 * p)
            twist.timingMode = .easeOut
            let bob = SCNAction.repeatForever(.sequence([
                .move(by: SCNVector3(0, 0.012, 0), duration: 1.4),
                .move(by: SCNVector3(0, -0.012, 0), duration: 1.4),
            ]))
            cap.runAction(.sequence([.wait(duration: 1.45 * p),
                                     .group([lift, twist]), bob]))

            // 4. Beam appears behind the rising lid, then pulses.
            beam.isHidden = false
            beam.opacity = 0
            beam.runAction(.sequence([
                .wait(duration: 1.90 * p),
                .fadeIn(duration: 0.5 * p),
                .repeatForever(.sequence([
                    .fadeOpacity(to: 0.5, duration: 0.85),
                    .fadeOpacity(to: 1.0, duration: 0.85),
                ])),
            ]))

            // The lamp pulses, so the violet falls on the bottle instead of replacing
            // its colour.
            let period = 1.7
            let breathe = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.light?.intensity = CGFloat(3 + 11 * phase)
            }
            lamp?.runAction(.sequence([.wait(duration: 1.90 * p),
                                       .repeatForever(breathe)]))
        }
    }
}
