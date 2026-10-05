import SceneKit
import simd
import UIKit

/// The hand in "put the band on": the ring sheet's hand closed into a fist (`BandHand.bin`, baked
/// by `bake_hand.py --fist` in the same hand space, forearm and all), and the real band coming in
/// past the knuckles — held open, as an elastic
/// loop is, its weave stretched and its pod as rigid as ever — to slide over the hand and close
/// round the wrist.
///
/// Hand space is the ring's: one unit is the ring's outer radius, the index finger runs down +X,
/// the back of the hand faces +Y, so the arm runs down −X. Where the band goes and how far it
/// must open to clear the hand are measured off the mesh, so a re-baked hand still fits.
enum BandHandModel {
    /// The fist shipped with the app.
    static let bundled: RingHandModel.Mesh? = RingHandModel.bundled("BandHand")

    /// The wrist: the arm's narrowest section, just before the palm widens.
    static let wristX: Float = -7.7
    /// The strap's width on the wrist, as a scale of the band's own (24 mm) strap.
    static let strapScale: Float = 1.87
    /// Room left between the wrist and the loop's inside.
    static let fit: Float = 0.03
    /// The loop's inside is fuller than an ellipse (a flat front, a squarish back): the exponent
    /// of the superellipse that stands in for it when measuring what clears the hand.
    static let insideShape: Float = 2.5

    /// The loop's inside, in the band's own units (32 mm each): half its height along the pod,
    /// half its depth, and how far the middle of the opening sits below the band's centre — the
    /// pod's body takes 4 mm of the inside.
    static var insideHalfHeight: Float { Float(BandModel.loopHalfHeight - BandModel.strapThickness / 2) / 32 }
    static var insideHalfDepth: Float {
        Float(BandModel.loopHalfDepth - BandModel.strapThickness / 2 - BandModel.podDepth / 2) / 32
    }
    static var insideDrop: Float { Float(BandModel.podDepth / 2) / 32 }

    // MARK: Measuring the hand

    /// A cross-section of the arm: its middle (y, z) and its radius at evenly spaced angles round
    /// that middle, angle 0 toward +Y (the back of the hand), a quarter turn toward +Z.
    struct Section {
        var centre: SIMD2<Float>
        var radii: [Float]

        /// Half its extent toward the back of the hand (y) and across it (z).
        var halfY: Float { radii.indices.map { radii[$0] * abs(cos(angle($0))) }.max() ?? 0 }
        var halfZ: Float { radii.indices.map { radii[$0] * abs(sin(angle($0))) }.max() ?? 0 }

        func angle(_ i: Int) -> Float { Float(i) / Float(radii.count) * 2 * .pi }
    }

    /// The arm's section at `x`, from the vertices within `slab` of it, its outline smoothed
    /// `smoothing` times.
    static func section(_ points: [SIMD3<Float>], at x: Float, slab: Float = 0.12, steps: Int = 36,
                        smoothing: Int = 2) -> Section? {
        let near = points.filter { abs($0.x - x) < slab }
        guard near.count >= 12, let minY = near.map(\.y).min(), let maxY = near.map(\.y).max(),
              let minZ = near.map(\.z).min(), let maxZ = near.map(\.z).max() else { return nil }
        let centre = SIMD2((minY + maxY) / 2, (minZ + maxZ) / 2)
        var radii = [Float](repeating: 0, count: steps)
        for p in near {
            let d = SIMD2(p.y, p.z) - centre
            var a = atan2(d.y, d.x)
            if a < 0 { a += 2 * .pi }
            let i = Int(a / (2 * .pi) * Float(steps)) % steps
            radii[i] = max(radii[i], simd_length(d))
        }
        // An empty step takes its neighbours' radius, then the outline is smoothed.
        let filled = radii.indices.map { i -> Float in
            guard radii[i] == 0 else { return radii[i] }
            var before = 0, after = 0
            while radii[(i - before - 1 + steps) % steps] == 0 && before < steps { before += 1 }
            while radii[(i + after + 1) % steps] == 0 && after < steps { after += 1 }
            return (radii[(i - before - 1 + steps) % steps] + radii[(i + after + 1) % steps]) / 2
        }
        var smooth = filled
        for _ in 0..<smoothing {
            smooth = smooth.indices.map { i in
                (smooth[(i - 1 + steps) % steps] + 2 * smooth[i] + smooth[(i + 1) % steps]) / 4
            }
        }
        return Section(centre: centre, radii: smooth)
    }

    // MARK: The ghost

    /// A tube along the arm from `x0` to `x1` with `section`'s outline, its radius scaled by
    /// `grow(t)` (t runs 0 → 1 along it). Open at both ends.
    static func loft(_ section: Section, from x0: Float, to x1: Float, rings: Int,
                     grow: (Float) -> Float) -> SCNGeometry {
        let steps = section.radii.count
        func point(_ ring: Int, _ step: Int) -> SIMD3<Float> {
            let t = Float(ring) / Float(rings - 1)
            let i = (step % steps + steps) % steps
            let a = section.angle(i)
            let r = section.radii[i] * grow(t)
            return SIMD3(x0 + (x1 - x0) * t, section.centre.x + r * cos(a), section.centre.y + r * sin(a))
        }
        func outward(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(0, p.y - section.centre.x, p.z - section.centre.y)
        }
        var positions: [SCNVector3] = [], normals: [SCNVector3] = []
        for ring in 0..<rings {
            for step in 0..<steps {
                let p = point(ring, step)
                let around = point(ring, step + 1) - point(ring, step - 1)
                let along = point(min(ring + 1, rings - 1), step) - point(max(ring - 1, 0), step)
                var n = simd_normalize(simd_cross(along, around))
                if simd_dot(n, outward(p)) < 0 { n = -n }
                positions.append(SCNVector3(p))
                normals.append(SCNVector3(n))
            }
        }
        // Faces wound to face out: check one against its outward direction.
        let a0 = point(0, 0), face = simd_cross(point(1, 0) - a0, point(0, 1) - a0)
        let flip = simd_dot(face, outward(a0)) < 0
        var indices: [UInt32] = []
        for ring in 0..<(rings - 1) {
            for step in 0..<steps {
                let a = UInt32(ring * steps + step), b = UInt32(ring * steps + (step + 1) % steps)
                let c = UInt32((ring + 1) * steps + step), d = UInt32((ring + 1) * steps + (step + 1) % steps)
                indices += flip ? [a, b, c, b, d, c] : [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: The band's way over the hand

    /// From past the fingertip (s = 0) to the wrist (s = 1): where the middle of the band's
    /// opening is, and how much wider than on the wrist its inside is there.
    struct Path {
        struct Stop {
            var x: Float
            var centre: SIMD2<Float>
            var stretch: Float
        }

        let stops: [Stop]
        /// The band's scale on the wrist, along its own axes (strap, along the pod, through it).
        let seat: SIMD3<Float>

        /// The band's position at `s`, and how far its strap is opened (`BandModel.stretch`).
        func at(_ s: Float) -> (position: SIMD3<Float>, open: Double) {
            let f = min(max(s, 0), 1) * Float(stops.count - 1)
            let i = min(Int(f), stops.count - 2)
            let t = f - Float(i)
            let a = stops[i], b = stops[i + 1]
            let x = a.x + (b.x - a.x) * t
            let centre = a.centre + (b.centre - a.centre) * t
            let k = a.stretch + (b.stretch - a.stretch) * t
            // The band's centre sits above the middle of its opening (the pod takes the inside).
            return (SIMD3(x, centre.x + BandHandModel.insideDrop * seat.z, centre.y), Self.open(k))
        }

        /// How far the strap opens for its inside to be `k` times its size on the wrist: it
        /// grows round its curves, the strap keeping its thickness, the front flat under the pod.
        static func open(_ k: Float) -> Double {
            let t = Double(BandModel.strapThickness) / 2, pod = Double(BandModel.podDepth) / 2
            let height = Double(BandHandModel.insideHalfHeight) * 32, depth = Double(BandHandModel.insideHalfDepth) * 32
            return max((Double(k) * height + t) / Double(BandModel.loopHalfHeight),
                       (Double(k) * depth + t + pod) / Double(BandModel.loopHalfDepth))
        }

        /// The most the loop opens on the way: the strap's morph target.
        var widest: Double { Self.open(stops.map(\.stretch).max() ?? 1) }
    }

    /// Measures the way: the loop opens enough to clear each section of the hand ahead of it,
    /// centred where it needs to open least, and closes as the hand narrows toward the wrist.
    static func path(_ mesh: RingHandModel.Mesh, wrist: Section) -> Path {
        let points = mesh.positions
        let seat = SIMD3(strapScale,
                         (wrist.halfZ + fit) / insideHalfHeight,
                         (wrist.halfY + fit) / insideHalfDepth)
        // The loop's inside on the wrist, in hand space: through the wrist (y) and across it (z).
        let insideY = insideHalfDepth * seat.z, insideZ = insideHalfHeight * seat.y

        // Just past the knuckles: the band comes into the frame there, already open.
        let start = (points.map(\.x).max() ?? mesh.tip.x) + 0.8
        let count = 56
        let xs = (0..<count).map { start + (wristX - start) * Float($0) / Float(count - 1) }
        // Sections along the way; past the fingertip there is no hand.
        typealias Slice = (centre: SIMD2<Float>, points: [SIMD2<Float>])
        let slices = xs.map { x -> Slice? in
            let near = points.filter { abs($0.x - x) < 0.2 }
            guard near.count >= 6, let minY = near.map(\.y).min(), let maxY = near.map(\.y).max(),
                  let minZ = near.map(\.z).min(), let maxZ = near.map(\.z).max() else { return nil }
            return (SIMD2((minY + maxY) / 2, (minZ + maxZ) / 2), near.map { SIMD2($0.y, $0.z) })
        }
        let n = insideShape
        func need(_ slice: Slice, at centre: SIMD2<Float>) -> Float {
            pow(slice.points.map { p in
                let d = abs(p - centre)
                return pow(d.x / insideY, n) + pow(d.y / insideZ, n)
            }.max() ?? 1, 1 / n)
        }
        // Where in the section the loop needs to open least.
        func best(_ slice: Slice) -> SIMD2<Float> {
            var centre = slice.centre, least = need(slice, at: centre)
            for dy in stride(from: Float(-0.6), through: 0.6, by: 0.15) {
                for dz in stride(from: Float(-0.6), through: 0.6, by: 0.15) {
                    let c = slice.centre + SIMD2(dy, dz), v = need(slice, at: c)
                    if v < least { least = v; centre = c }
                }
            }
            return centre
        }
        let bestCentres = slices.map { $0.map(best) }
        // The widest section: the band comes in on its line, already open.
        let widest = slices.indices.compactMap { i in slices[i].map { (i, need($0, at: bestCentres[i]!)) } }
            .max { $0.1 < $1.1 }?.0 ?? 0
        var centres = slices.indices.map { i -> SIMD2<Float> in
            guard i > widest, let centre = bestCentres[i] else { return bestCentres[widest] ?? wrist.centre }
            return centre
        }
        centres[count - 1] = wrist.centre
        // Ease the line between the widest point and the wrist.
        for _ in 0..<3 {
            centres = centres.indices.map { i in
                guard i > widest, i < count - 1 else { return centres[i] }
                return (centres[i - 1] + 2 * centres[i] + centres[i + 1]) / 4
            }
        }
        // Open enough for everything still ahead, never less than the seat.
        var needs = slices.indices.map { i in slices[i].map { need($0, at: centres[i]) * 1.03 } ?? 1 }
        needs[count - 1] = 1
        var floor = [Float](repeating: 1, count: count)
        var ahead: Float = 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            ahead = max(ahead, needs[i])
            floor[i] = ahead
        }
        let stretch = closing(floor)
        let stops = (0..<count).map { Path.Stop(x: xs[$0], centre: centres[$0], stretch: stretch[$0]) }
        return Path(stops: stops, seat: seat)
    }

    /// How the loop closes on the way in: smoothly, never tighter than `floor` (what the hand
    /// still ahead needs), and exactly its seat at the end. The hand's own profile drops at the
    /// knuckles and again into the wrist; followed as it is, the strap snapped shut. Held open a
    /// little longer (each value pushed `lag` stops toward the wrist, where it is never less than
    /// the floor) and blurred over about as many, it eases closed instead; the last stops close
    /// the rest of the way.
    static func closing(_ floor: [Float], lag: Int = 6) -> [Float] {
        let count = floor.count
        let held = (0..<count).map { floor[max(0, $0 - lag)] }
        let sigma = Float(lag) / 2
        let reach = lag
        var smooth = (0..<count).map { i -> Float in
            var sum: Float = 0, weight: Float = 0
            for j in max(0, i - reach)...min(count - 1, i + reach) {
                let w = exp(-Float((j - i) * (j - i)) / (2 * sigma * sigma))
                sum += held[j] * w
                weight += w
            }
            return max(floor[i], sum / weight)
        }
        // Into the seat: the last `lag` stops ease what is left of the opening to nothing.
        for i in (count - lag)..<count {
            let t = Float(i - (count - lag - 1)) / Float(lag)
            let ease = t * t * (3 - 2 * t)
            smooth[i] = max(floor[i], 1 + (smooth[i] - 1) * (1 - ease))
        }
        smooth[count - 1] = 1
        // Only ever closing: the blur's window is cut short at the ends. Still never under the
        // floor — the floor only falls, and each value stays at or above its own.
        for i in 1..<count { smooth[i] = min(smooth[i], smooth[i - 1]) }
        return smooth
    }

    /// The slide's pace: it picks up gently, travels, and takes its time arriving — the loop
    /// closes during that long arrival. A cubic Bézier through (0.45, 0) and (0.15, 1).
    static func slideEase(_ t: Float) -> Float {
        func bezier(_ u: Float, _ a: Float, _ b: Float) -> Float {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        // x(u) = t, solved by halving: x rises with u for these control points.
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.45, 0.15) < min(max(t, 0), 1) { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0, 1)
    }

    // MARK: The stage

    /// The hand, its forearm, the band and the light on them.
    ///
    /// The band is passed in (the real `BandModel`, strap and hardware apart so the strap can
    /// stretch): its strap's width along X, the loop's height along Y and the pod facing +Z,
    /// centred on its middle. The stage lays it round the arm with the pod on the back of the wrist.
    final class Stage {
        let scene = SCNScene()
        let camera = SCNNode()
        private let holder = SCNNode()
        private let halo = SCNNode()
        private let band: BandModel.Parts
        let path: Path

        /// Palm down, tipped toward the camera so the back of the hand and the wrist show — the
        /// ring sheet's pose, turned a little so the forearm leaves the frame on the left.
        static let handEuler = SCNVector3(0.9, -0.2, 0.0)
        /// The point of the hand the camera centres on, and how far back it stands.
        static let lookAt = SIMD3<Float>(-4.6, -0.9, 1.0)
        static let distance: Float = 23

        init?(band: BandModel.Parts, hand mesh: RingHandModel.Mesh, accent: CGColor,
              pose: SCNVector3 = Stage.handEuler, lookAt: SIMD3<Float> = Stage.lookAt,
              distance: Float = Stage.distance) {
            guard let wrist = BandHandModel.section(mesh.positions, at: BandHandModel.wristX) else { return nil }
            self.band = band
            path = BandHandModel.path(mesh, wrist: wrist)
            let morpher = SCNMorpher()
            morpher.calculationMode = .normalized
            morpher.targets = [BandModel.stretchedStrap(open: path.widest)]
            band.strap.morpher = morpher
            scene.background.contents = CGColor(gray: 0, alpha: 0)
            if let environment = RingHandModel.environment {
                scene.lightingEnvironment.contents = environment
                scene.lightingEnvironment.intensity = 1.1
            }

            let hand = SCNNode()
            hand.addChildNode(RingHandModel.makeHand(mesh))

            // The band's X along the arm, its Y round the wrist's width, the pod (+Z) up on the
            // back of the wrist (+Y).
            holder.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
            holder.simdScale = path.seat
            holder.addChildNode(band.pivot)
            hand.addChildNode(holder)

            // A ghost band in the accent, round the wrist where the band will close.
            var ghost = wrist
            ghost.radii = ghost.radii.map { $0 * 1.07 }
            let halfStrap = Float(BandModel.strapWidth) / 32 * BandHandModel.strapScale / 2
            let haloGeometry = BandHandModel.loft(ghost, from: BandHandModel.wristX + halfStrap,
                                                  to: BandHandModel.wristX - halfStrap, rings: 2) { _ in 1 }
            let glow = SCNMaterial()
            glow.lightingModel = .constant
            glow.diffuse.contents = accent
            glow.transparency = 0.6
            glow.writesToDepthBuffer = false
            haloGeometry.materials = [glow]
            halo.geometry = haloGeometry
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
            camera.simdPosition = root.simdConvertPosition(lookAt, to: nil) + SIMD3(0, 0, distance)
            scene.rootNode.addChildNode(camera)
            place(0)
        }

        private func place(_ s: Float) {
            let at = path.at(s)
            holder.simdPosition = at.position
            BandModel.stretch(band, open: at.open, target: path.widest)
        }

        /// Holds one pose, for the render harness: on the wrist, or `s` of the way there (0 is past
        /// the fingertip) with the ghost showing where it goes.
        func pose(seated: Bool) { pose(along: seated ? 1 : 0) }

        func pose(along s: Float, ghost: Bool = true) {
            holder.removeAllActions()
            halo.removeAllActions()
            holder.opacity = 1
            place(s)
            halo.opacity = ghost && s < 1 ? 0.85 : 0
        }

        /// The gesture, on a loop: the ghost marks the wrist, the band comes in past the knuckles
        /// held open, slides over the hand and closes round the wrist, holds, and fades to come
        /// round again. The hand never moves. Both loops run 4.95 s.
        func play() {
            holder.removeAllActions()
            halo.removeAllActions()

            let slideTime: TimeInterval = 2.4
            let slide = SCNAction.customAction(duration: slideTime) { [weak self] _, elapsed in
                self?.place(BandHandModel.slideEase(Float(min(1, elapsed / CGFloat(slideTime)))))
            }
            let band = SCNAction.sequence([
                .run { [weak self] node in node.opacity = 0; self?.place(0) },
                .wait(duration: 0.5),
                .group([.fadeIn(duration: 0.35), slide]),
                .wait(duration: 1.4),
                .fadeOut(duration: 0.4),
                .wait(duration: 0.25),
            ])
            holder.runAction(.repeatForever(band), forKey: "gesture")

            // The ghost breathes while the wrist is bare and goes out as the band closes on it.
            let glow = SCNAction.sequence([
                .run { node in node.opacity = 0 },
                .fadeOpacity(to: 0.85, duration: 0.35),
                .fadeOpacity(to: 0.5, duration: 0.6),
                .wait(duration: 1.0),
                .fadeOut(duration: 0.6),
                .wait(duration: 2.4),
            ])
            halo.runAction(.repeatForever(glow), forKey: "gesture")
        }
    }
}
