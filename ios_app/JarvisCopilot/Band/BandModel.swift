import SceneKit
import UIKit
import simd

/// A procedural HBand (Veepoo) screenless band, after the product photo: a closed loop of black
/// elastic woven in a small diamond twill, matte and a little fuzzy, like a Whoop band; on its
/// flat side a slim gunmetal pod — the strap runs over the pod's face between its two side rails
/// and dives under a plate at its foot, and the right rail carries a red pulse mark — then a
/// gunmetal buckle bar below it that the strap passes through. Against the wrist, the sensor
/// window and its LEDs. Colours were matched to the photo by sampling it: the weave ~21/255, the
/// rails ~64, the plate ~100.
///
/// The loop stands upright: Y runs along the pod, the strap's width is X, the pod faces +Z. Built
/// in millimetres and scaled 32 mm to the unit, so the loop is about 2 tall — the rings' size,
/// for the same cameras.
enum BandModel {
    private static let unit: Float = 1.0 / 32

    // The strap: 24 mm of woven elastic, 2.6 mm thick, about 195 mm round.
    static let strapWidth: CGFloat = 24
    static let strapThickness: CGFloat = 2.6
    /// The centreline's half-height (along the pod) and half-depth. Taller than deep, as a wrist is
    /// wider than thick, with the pod on the broad side.
    static let loopHalfHeight: CGFloat = 31.5
    static let loopHalfDepth: CGFloat = 25.5
    /// Where the front stops running flat, above and below centre: the pod and the buckle hold it
    /// straight between.
    private static let flatTop: CGFloat = 19
    private static let flatBottom: CGFloat = -24.5

    // The pod, measured off the photo against the strap's width: 38 long, 27.5 across (a rail of
    // 1.75 each side of the strap), 4 deep under the strap. The plate covers its foot.
    static let podLength: CGFloat = 38
    static let podWidth: CGFloat = 27.5
    static let podDepth: CGFloat = 4
    private static let podTop: CGFloat = 18.5
    private static let podCorner: CGFloat = 2.4
    private static let railWidth: CGFloat = (podWidth - strapWidth) / 2
    private static let plateLength: CGFloat = 8
    private static var podBottom: CGFloat { podTop - podLength }

    /// The strap's faces along the flat front.
    private static var strapInner: CGFloat { loopHalfDepth - strapThickness / 2 }
    private static var strapOuter: CGFloat { loopHalfDepth + strapThickness / 2 }

    static let defaultTilt: Float = 0.16
    /// Turned as in the photo: the pod's face to the left, its marked rail and the loop's
    /// opening to the right.
    static let defaultAngle: Float = -0.62

    /// One tile of the weave, in millimetres: six rows of the knit each way.
    static let fabricTile: Double = 9

    // MARK: Loop

    /// A point on the strap's centreline (mm, in the Y–Z plane) and the outward normal there.
    private struct Station {
        var y: Double
        var z: Double
        var ny: Double
        var nz: Double
    }

    /// The centreline, evenly spaced, from the bottom up the front, over the top and down the
    /// back. The back is a superellipse; the front runs flat under the pod and the buckle, then
    /// turns over in quarter-ellipses tangent to the flat and to the back, so the strap has no
    /// crease anywhere.
    private static func centreline(count: Int) -> (stations: [Station], length: Double) {
        let a = Double(loopHalfHeight), b = Double(loopHalfDepth)
        let top = Double(flatTop), bottom = Double(flatBottom)
        let back = 2 / 2.15
        let steps = 400
        var raw: [SIMD2<Double>] = []
        for i in 0..<steps {
            let p = Double(i) / Double(steps) * .pi / 2
            raw.append([bottom - (a + bottom) * cos(p), b * sin(p)])
        }
        for i in 0..<steps {
            raw.append([bottom + (top - bottom) * Double(i) / Double(steps), b])
        }
        for i in 0..<steps {
            let p = Double(i) / Double(steps) * .pi / 2
            raw.append([top + (a - top) * sin(p), b * cos(p)])
        }
        for i in 0..<(2 * steps) {
            let t = Double(i) / Double(2 * steps) * .pi
            let c = cos(t)
            raw.append([a * (c < 0 ? -1 : 1) * pow(abs(c), back), -b * pow(sin(t), back)])
        }
        // Resample by arc length, so the weave keeps its size round the corners.
        var run: [Double] = [0]
        for i in 1...raw.count {
            run.append(run[i - 1] + simd_distance(raw[i % raw.count], raw[i - 1]))
        }
        let total = run[raw.count]
        var points: [SIMD2<Double>] = []
        var j = 0
        for k in 0..<count {
            let target = total * Double(k) / Double(count)
            while run[j + 1] < target { j += 1 }
            let t = (target - run[j]) / max(1e-9, run[j + 1] - run[j])
            points.append(raw[j] + (raw[(j + 1) % raw.count] - raw[j]) * t)
        }
        let stations = (0..<count).map { k -> Station in
            let d = simd_normalize(points[(k + 1) % count] - points[(k + count - 1) % count])
            return Station(y: points[k].x, z: points[k].y, ny: -d.y, nz: d.x)
        }
        return (stations, total)
    }

    /// The strap's section, clockwise from the outer face's left edge: a ribbon with rounded
    /// edges. x is across the strap, r out from the centreline.
    private static var strapSection: [(x: Double, r: Double, nx: Double, nr: Double)] {
        let w = Double(strapWidth) / 2, t = Double(strapThickness) / 2, f = 0.9
        var section: [(x: Double, r: Double, nx: Double, nr: Double)] = []
        func arc(_ cx: Double, _ cr: Double, from a0: Double, to a1: Double) {
            for i in 1...6 {
                let a = a0 + (a1 - a0) * Double(i) / 6
                section.append((cx + f * cos(a), cr + f * sin(a), cos(a), sin(a)))
            }
        }
        func face(from p0: (Double, Double), to p1: (Double, Double), normal: (Double, Double)) {
            for i in 0...4 {
                let s = Double(i) / 4
                section.append((p0.0 + (p1.0 - p0.0) * s, p0.1 + (p1.1 - p0.1) * s, normal.0, normal.1))
            }
        }
        face(from: (-w + f, t), to: (w - f, t), normal: (0, 1))
        arc(w - f, t - f, from: .pi / 2, to: 0)
        face(from: (w, t - f), to: (w, -t + f), normal: (1, 0))
        arc(w - f, -t + f, from: 0, to: -.pi / 2)
        face(from: (w - f, -t), to: (-w + f, -t), normal: (0, -1))
        arc(-w + f, -t + f, from: -.pi / 2, to: -.pi)
        face(from: (-w, -t + f), to: (-w, t - f), normal: (-1, 0))
        arc(-w + f, t - f, from: .pi, to: .pi / 2)
        return section
    }

    /// The section swept round the centreline. u runs round the loop, v across the strap; the
    /// tangents follow u so the weave's normal map lies along the strap.
    private static func strapGeometry() -> (geometry: SCNGeometry, length: Double) {
        let (stations, length) = centreline(count: 480)
        let section = strapSection
        let w = Double(strapWidth) / 2
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var tangents: [SIMD4<Float>] = []
        var uvs: [CGPoint] = []
        for p in section {
            for k in 0...stations.count {
                let s = stations[k % stations.count]
                positions.append(SCNVector3(Float(p.x), Float(s.y + s.ny * p.r), Float(s.z + s.nz * p.r)))
                normals.append(SCNVector3(Float(p.nx), Float(s.ny * p.nr), Float(s.nz * p.nr)))
                tangents.append(SIMD4<Float>(0, Float(s.nz), Float(-s.ny), 1))
                uvs.append(CGPoint(x: Double(k) / Double(stations.count), y: (p.x + w) / (2 * w)))
            }
        }
        var indices: [Int32] = []
        let row = stations.count + 1
        for i in 0..<(section.count - 1) {
            for k in 0..<stations.count {
                let a = Int32(i * row + k), b = Int32(i * row + k + 1)
                let c = Int32((i + 1) * row + k), d = Int32((i + 1) * row + k + 1)
                indices += [a, c, b, b, c, d]
            }
        }
        let tangentData = tangents.withUnsafeBufferPointer { Data(buffer: $0) }
        let tangentSource = SCNGeometrySource(
            data: tangentData, semantic: .tangent, vectorCount: tangents.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                      SCNGeometrySource(textureCoordinates: uvs), tangentSource],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        return (geometry, length)
    }

    // MARK: Hardware

    /// A rounded rectangle with true circular corners (`UIBezierPath(roundedRect:)` draws
    /// continuous ones, which the plate's foot could not follow).
    private static func roundedRect(_ rect: CGRect, radius r: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.close()
        return path
    }

    /// An outline drawn in the side view — path x is the model's z, path y its y — and extruded
    /// across the strap by `width`, centred on `x`.
    private static func sidePiece(_ path: UIBezierPath, width: CGFloat, chamfer: CGFloat, x: Float = 0,
                                  material: SCNMaterial) -> SCNNode {
        path.flatness = 0.02
        let shape = SCNShape(path: path, extrusionDepth: width)
        shape.chamferRadius = chamfer
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.eulerAngles.y = -.pi / 2
        node.position.x = x
        return node
    }

    private static func rect(z: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> CGRect {
        CGRect(x: z.lowerBound, y: y.lowerBound, width: z.upperBound - z.lowerBound,
               height: y.upperBound - y.lowerBound)
    }

    /// The plate over the pod's foot, its end following the rails' rounded corner so the two
    /// read as one housing.
    private static var plateOutline: UIBezierPath {
        let back = strapOuter - 0.5, face = strapOuter + 0.3
        let r = podCorner - 0.05
        let centre = CGPoint(x: strapOuter + 0.35 - podCorner, y: podBottom + podCorner)
        let sweep = acos((back - centre.x) / r)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: back, y: podBottom + plateLength))
        path.addLine(to: CGPoint(x: face, y: podBottom + plateLength))
        path.addLine(to: CGPoint(x: face, y: centre.y))
        path.addArc(withCenter: centre, radius: r, startAngle: 0, endAngle: -sweep, clockwise: false)
        path.close()
        return path
    }

    /// The red pulse trace on the right rail, near its foot: a vertical zigzag of short bars.
    private static func pulseMark(_ material: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        let top = podTop - 0.74 * podLength, bottom = podTop - 0.91 * podLength
        let centre = strapInner - 1.0
        // (offset across the rail, fraction of the way down)
        let trace: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.12), (0.75, 0.26), (-0.85, 0.42), (0.95, 0.58),
                                           (-0.75, 0.74), (0.4, 0.88), (0, 1)]
        for (p, q) in zip(trace, trace.dropFirst()) {
            let y0 = top - (top - bottom) * p.1, y1 = top - (top - bottom) * q.1
            let z0 = centre + p.0, z1 = centre + q.0
            let bar = SCNBox(width: 0.1, height: hypot(y1 - y0, z1 - z0) + 0.2, length: 0.2, chamferRadius: 0.04)
            bar.materials = [material]
            let segment = SCNNode(geometry: bar)
            segment.position = SCNVector3(Float(podWidth / 2 + 0.03), Float((y0 + y1) / 2), Float((z0 + z1) / 2))
            segment.eulerAngles.x = Float(atan2(z1 - z0, y1 - y0))
            node.addChildNode(segment)
        }
        return node
    }

    // MARK: Textures

    /// The weave, one seamless `fabricTile`: a knit of near-black yarn with small dark pits in
    /// staggered rows — each a little off its place and a little different in size, longer across
    /// the strap than along it, as in the photo — over a faint diagonal twill, with the yarn's
    /// uneven sheen and a fuzz of noise on top. Colour and normal map share one height field.
    /// u (the image's x) runs along the strap, v across it.
    static let fabric: (color: UIImage, normal: UIImage) = drawFabric()

    private static func drawFabric() -> (color: UIImage, normal: UIImage) {
        let n = 256, rows = 6
        var seed: UInt64 = 0x0BA4_D5EE_D1A0_0001
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        /// Smooth noise on a `cells`-square lattice, sampled at every pixel and wrapped so the
        /// tile repeats.
        func noise(cells: Int) -> [Double] {
            let lattice = (0..<(cells * cells)).map { _ in random() }
            var out = [Double](repeating: 0, count: n * n)
            for py in 0..<n {
                let gy = Double(py) / Double(n) * Double(cells)
                let y0 = Int(gy), y1 = (y0 + 1) % cells
                let fy = gy - Double(y0), sy = fy * fy * (3 - 2 * fy)
                for px in 0..<n {
                    let gx = Double(px) / Double(n) * Double(cells)
                    let x0 = Int(gx), x1 = (x0 + 1) % cells
                    let fx = gx - Double(x0), sx = fx * fx * (3 - 2 * fx)
                    let top = lattice[y0 * cells + x0] * (1 - sx) + lattice[y0 * cells + x1] * sx
                    let bottom = lattice[y1 * cells + x0] * (1 - sx) + lattice[y1 * cells + x1] * sx
                    out[py * n + px] = top * (1 - sy) + bottom * sy
                }
            }
            return out
        }
        let sheen = noise(cells: 12), loops = noise(cells: 48)
        // The pits, stamped one by one: a rows × rows lattice, alternate rows offset half a cell,
        // each pit nudged off its place and given its own size and depth, its edge ragged where
        // the yarn's loops cross it.
        var pit = [Double](repeating: 0, count: n * n)
        let cell = Double(n) / Double(rows)
        for row in 0..<rows {
            for col in 0..<rows {
                let stagger = row % 2 == 0 ? 0.0 : 0.5
                let cu = (Double(col) + stagger + 0.5 + (random() - 0.5) * 0.45) * cell
                let cv = (Double(row) + 0.5 + (random() - 0.5) * 0.4) * cell
                let size = 0.8 + 0.45 * random(), depth = 0.65 + 0.35 * random()
                let ru = 0.3 * cell * size, rv = 0.46 * cell * size
                for oy in Int(-rv)...Int(rv) {
                    for ox in Int(-ru)...Int(ru) {
                        let pu = Int(cu) + ox, pv = Int(cv) + oy
                        let su = (Double(pu) - cu) / ru, sv = (Double(pv) - cv) / rv
                        let i = ((pv % n + n) % n) * n + (pu % n + n) % n
                        let d = (su * su + sv * sv).squareRoot() + 0.45 * (loops[i] - 0.5)
                        let t = max(0, min(1, (1 - d) / 0.7))
                        pit[i] = max(pit[i], depth * t * t * (3 - 2 * t))
                    }
                }
            }
        }
        var height = [Double](repeating: 0, count: n * n)
        var color = [UInt8](repeating: 255, count: n * n * 4)
        for py in 0..<n {
            for px in 0..<n {
                let i = py * n + px
                let twill = 0.5 + 0.5 * cos(2 * .pi * Double(rows * 2) * Double(px + py) / Double(n))
                let fuzz = random()
                height[i] = 1 - 0.55 * pit[i] + 0.16 * twill + 0.08 * sheen[i] + 0.3 * loops[i] + 0.03 * fuzz
                let shade = 0.056 + 0.012 * twill + 0.03 * (sheen[i] - 0.5) + 0.035 * (loops[i] - 0.5)
                    + 0.02 * (fuzz - 0.5) - 0.055 * pit[i]
                let byte = UInt8(max(0, min(1, shade)) * 255)
                color[i * 4] = byte
                color[i * 4 + 1] = byte
                color[i * 4 + 2] = UInt8(min(255, Int(byte) + 2))
            }
        }
        var normal = [UInt8](repeating: 255, count: n * n * 4)
        let strength = 5.0
        for row in 0..<n {
            let up = (row + n - 1) % n * n, down = (row + 1) % n * n, here = row * n
            for col in 0..<n {
                let left = (col + n - 1) % n, right = (col + 1) % n
                let dx = (height[here + right] - height[here + left]) / 2 * strength
                let dy = (height[down + col] - height[up + col]) / 2 * strength
                let v = simd_normalize(SIMD3<Double>(-dx, dy, 1))
                let i = (here + col) * 4
                normal[i] = UInt8((v.x * 0.5 + 0.5) * 255)
                normal[i + 1] = UInt8((v.y * 0.5 + 0.5) * 255)
                normal[i + 2] = UInt8((v.z * 0.5 + 0.5) * 255)
            }
        }
        return (image(color, side: n), image(normal, side: n))
    }

    /// RGBA with its alpha kept: an opaque (BGRX) image is a pixel format Metal rejects for a
    /// texture.
    private static func image(_ bytes: [UInt8], side: Int) -> UIImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    // MARK: Materials

    /// Woven elastic: matte black, the weave in the normal map, and a soft lift where the strap
    /// turns away from the eye — the fuzz of the yarn catching the light.
    private static func fabricMaterial(length: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = fabric.color
        m.normal.contents = fabric.normal
        m.normal.intensity = 1.0
        let scale = SCNMatrix4MakeScale(Float((length / fabricTile).rounded()),
                                        Float((Double(strapWidth) / fabricTile).rounded()), 1)
        for property in [m.diffuse, m.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.mipFilter = .linear
            property.contentsTransform = scale
        }
        m.metalness.contents = 0.0
        m.roughness.contents = 0.86
        m.shaderModifiers = [.surface: """
            float rim = 1.0 - saturate(dot(_surface.normal, _surface.view));
            _surface.diffuse.rgb += pow(rim, 3.0) * 0.06;
            """]
        return m
    }

    /// Satin gunmetal, darker than steel: a mostly metallic dark grey, rough enough that the
    /// studio smears into soft highlights along the edges.
    private static func gunmetal(_ white: CGFloat = 0.5, roughness: CGFloat = 0.17) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: white * 0.97, green: white * 0.98, blue: white, alpha: 1)
        m.metalness.contents = 0.9
        m.roughness.contents = roughness
        return m
    }

    private static func markMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 0.55, green: 0.06, blue: 0.08, alpha: 1)
        m.emission.contents = UIColor(red: 1, green: 0.16, blue: 0.2, alpha: 1)
        m.emission.intensity = Live.idleMark
        return m
    }

    private static func lensMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.04
        return m
    }

    private static func ledMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        m.emission.contents = color
        m.emission.intensity = Live.idleLED
        return m
    }

    // MARK: Assembly

    struct Parts {
        let pivot: SCNNode
        let spinner: SCNNode
        let leds: [SCNNode]
        let glow: SCNNode
        let mark: SCNMaterial
    }

    static func makeNode() -> Parts {
        let band = SCNNode()
        band.scale = SCNVector3(unit, unit, unit)

        let (strap, length) = strapGeometry()
        strap.materials = [fabricMaterial(length: length)]
        band.addChildNode(SCNNode(geometry: strap))

        // The pod: a body under the strap, and two rails the full depth either side of it whose
        // tops stand just proud of the weave.
        let metal = gunmetal()
        let pod = rect(z: (strapInner - podDepth)...(strapOuter + 0.35), y: podBottom...podTop)
        let railX = Float(podWidth / 2 - railWidth / 2)
        for side: Float in [-1, 1] {
            band.addChildNode(sidePiece(roundedRect(pod, radius: podCorner), width: railWidth, chamfer: 0.42,
                                        x: side * railX, material: metal))
        }
        let body = rect(z: (strapInner - podDepth + 0.15)...(strapInner + 0.1),
                        y: (podBottom + 0.15)...(podTop - 0.15))
        band.addChildNode(sidePiece(roundedRect(body, radius: podCorner - 0.15), width: strapWidth + 0.4,
                                    chamfer: 0.6, material: metal))
        // The seam along each side where the housing's halves meet.
        let seamMaterial = gunmetal(0.12, roughness: 0.5)
        for side: Float in [-1, 1] {
            let seam = SCNBox(width: 0.06, height: podLength - 2 * podCorner, length: 0.16, chamferRadius: 0.02)
            seam.materials = [seamMaterial]
            let node = SCNNode(geometry: seam)
            node.position = SCNVector3(side * Float(podWidth / 2 + 0.02), Float(podTop - podLength / 2),
                                       Float(strapInner + 0.5))
            band.addChildNode(node)
        }
        band.addChildNode(sidePiece(plateOutline, width: strapWidth + 0.6, chamfer: 0.22, material: gunmetal(0.85, roughness: 0.3)))

        // The buckle: a bar across the strap a little below the pod, its tabs running back round
        // the strap's edges to a bar inside.
        let buckle = gunmetal(0.7, roughness: 0.24)
        let barTop = podBottom - 0.7, barBottom = barTop - 3.2
        let buckleWidth: CGFloat = podWidth, tab: CGFloat = 1.5, drop: CGFloat = 1.6
        let insideFace = strapInner - 0.5, insideBack = insideFace - 1.4
        band.addChildNode(sidePiece(roundedRect(rect(z: (strapOuter + 0.1)...(strapOuter + 1.05), y: barBottom...barTop),
                                                radius: 0.4),
                                    width: buckleWidth, chamfer: 0.25, material: buckle))
        band.addChildNode(sidePiece(roundedRect(rect(z: insideBack...insideFace, y: (barBottom - drop)...(barTop - drop)),
                                                radius: 0.5),
                                    width: buckleWidth, chamfer: 0.3, material: buckle))
        for side: Float in [-1, 1] {
            let outline = UIBezierPath()
            outline.move(to: CGPoint(x: strapOuter + 1.05, y: barTop))
            outline.addLine(to: CGPoint(x: strapOuter + 1.05, y: barBottom))
            outline.addLine(to: CGPoint(x: insideBack, y: barBottom - drop))
            outline.addLine(to: CGPoint(x: insideBack, y: barTop - drop))
            outline.close()
            band.addChildNode(sidePiece(outline, width: tab, chamfer: 0.25,
                                        x: side * Float(buckleWidth / 2 - tab / 2), material: buckle))
        }

        let mark = markMaterial()
        band.addChildNode(pulseMark(mark))

        // Inside, against the wrist: the sensor window, with the optical sensor's LEDs in it.
        let podBack = strapInner - podDepth + 0.15
        let podMiddle = (podTop + podBottom) / 2 + 2
        let lens = SCNShape(path: roundedRect(CGRect(x: -6.5, y: podMiddle - 9, width: 13, height: 18), radius: 3),
                            extrusionDepth: 0.6)
        lens.chamferRadius = 0.2
        lens.materials = [lensMaterial()]
        let window = SCNNode(geometry: lens)
        window.position.z = Float(podBack - 0.2)
        band.addChildNode(window)
        let green = UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)
        var leds: [SCNNode] = []
        for (x, y, color) in [(-2.2, podMiddle + 3, green), (2.2, podMiddle + 3, green),
                              (0, podMiddle - 3, UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))] {
            let die = SCNBox(width: 1.3, height: 1.0, length: 0.2, chamferRadius: 0.08)
            die.materials = [ledMaterial(color)]
            let node = SCNNode(geometry: die)
            node.position = SCNVector3(Float(x), Float(y), Float(podBack - 0.55))
            band.addChildNode(node)
            leds.append(node)
        }

        let glow = SCNNode()
        let light = SCNLight()
        light.type = .omni
        light.color = UIColor(red: 0.3, green: 1, blue: 0.45, alpha: 1)
        light.intensity = 0
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = 0.9
        glow.light = light
        glow.position = SCNVector3(0, Float(podMiddle) * unit, Float(podBack - 5) * unit)

        let spinner = SCNNode()
        spinner.addChildNode(band)
        spinner.addChildNode(glow)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, leds: leds, glow: glow, mark: mark)
    }

    // MARK: Scene

    /// One scene plus the nodes that animate. Held by `BandSceneView`.
    final class Live {
        static let idleLED: CGFloat = 0.15
        static let idleMark: CGFloat = 0.45

        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let leds: [SCNNode]
        private let glow: SCNNode
        private let mark: SCNMaterial
        private var measuring = false

        init(spin: Bool, tilt: Float = BandModel.defaultTilt, cameraDistance: Float = 4.6,
             spinSeconds: Double = 34, spinAngle: Float = BandModel.defaultAngle) {
            let parts = BandModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            leds = parts.leds
            glow = parts.glow
            mark = parts.mark

            scene.background.contents = UIColor.clear
            scene.lightingEnvironment.contents = RingModel.environment
            scene.lightingEnvironment.intensity = 1.6
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(tilt, 0, 0)
            spinner.eulerAngles.y = spinAngle
            if spin {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)), forKey: "spin")
            }

            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 700, .white, SCNVector3(-0.6, 0.5, 0)),
                (.directional, 260, UIColor(red: 0.8, green: 0.87, blue: 1, alpha: 1), SCNVector3(-0.2, -2.3, 0)),
                (.directional, 350, .white, SCNVector3(0.9, 2.8, 0)),
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

        /// While a measurement runs the LEDs breathe, cast a green glow inside the loop, and the
        /// red pulse mark beats with them.
        func setPulsing(_ on: Bool) {
            measuring = on
            pulse(on)
        }

        private func pulse(_ on: Bool) {
            leds.forEach { $0.removeAction(forKey: "pulse") }
            glow.removeAction(forKey: "pulse")
            let mark = self.mark
            guard on else {
                leds.forEach { $0.geometry?.firstMaterial?.emission.intensity = Self.idleLED }
                glow.light?.intensity = 0
                mark.emission.intensity = Self.idleMark
                return
            }
            let period = 1.0
            let idle = Self.idleLED, idleMark = Self.idleMark
            let pulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.geometry?.firstMaterial?.emission.intensity = idle + (2 - idle) * CGFloat(phase)
            }
            leds.forEach { $0.runAction(.repeatForever(pulse), forKey: "pulse") }
            let glowPulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.light?.intensity = CGFloat(40 * phase)
                mark.emission.intensity = idleMark + (1.6 - idleMark) * CGFloat(phase)
            }
            glow.runAction(.repeatForever(glowPulse), forKey: "pulse")
        }

        /// "Find band": a quick hop and a burst of LED light.
        func flash() {
            let hop = SCNAction.sequence([.scale(to: 1.08, duration: 0.12), .scale(to: 1.0, duration: 0.18)])
            pivot.runAction(.repeat(hop, count: 3), forKey: "hop")
            pulse(true)
            pivot.runAction(.sequence([.wait(duration: 2.0), .run { [weak self] _ in
                guard let self else { return }
                self.pulse(self.measuring)
            }]), forKey: "flash")
        }
    }
}
