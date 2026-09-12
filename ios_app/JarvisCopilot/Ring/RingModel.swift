import SceneKit
import UIKit

/// A procedural Colmi R12, after the real ring: a glossy gunmetal shell with polished inner lips,
/// and a clear resin band over the inside — the segmented flex board with its chips, pale metal
/// parts, passives and rows of solder down one arc, the round magnetic charging port set into it,
/// and "SMART RING · FC CE · 9" with the crossed-out bin laser-etched on the arc opposite.
///
/// The ring's axis is Y. The profile is a rounded rectangle in (radius, height) lathed around
/// that axis; the inner face is split off so the resin and the board behind it can differ.
enum RingModel {
    // A real R12 is ~23.5 mm across, 6.8 mm wide, with a 2.3 mm wall — so the band is a little
    // over a quarter of the ring's diameter. The model used to draw it at a third, which is what
    // made it look stocky next to a photograph of the ring.
    static let outerRadius: CGFloat = 1.0
    static let innerRadius: CGFloat = 0.805
    static let width: CGFloat = 0.58
    /// Leans the ring toward the camera so the inside — board, sensor, LEDs — shows.
    static let defaultTilt: Float = 0.95
    private static let fillet: CGFloat = 0.082
    /// How far behind the resin the board sits.
    private static let boardDepth: CGFloat = 0.03

    private struct ProfilePoint {
        var r: CGFloat
        var y: CGFloat
        var nr: CGFloat
        var ny: CGFloat
    }

    // MARK: Profile

    private static func arc(r cr: CGFloat, y cy: CGFloat, radius: CGFloat,
                            from a0: CGFloat, to a1: CGFloat, steps: Int) -> [ProfilePoint] {
        (0...steps).map { i in
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            return ProfilePoint(r: cr + radius * cos(a), y: cy + radius * sin(a), nr: cos(a), ny: sin(a))
        }
    }

    private static func line(from p0: (CGFloat, CGFloat), to p1: (CGFloat, CGFloat),
                             normal: (CGFloat, CGFloat), steps: Int) -> [ProfilePoint] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return ProfilePoint(r: p0.0 + (p1.0 - p0.0) * t, y: p0.1 + (p1.1 - p0.1) * t, nr: normal.0, ny: normal.1)
        }
    }

    /// The top, outer face and bottom, traced clockwise from the top lip to the bottom lip.
    private static var shellProfile: [ProfilePoint] {
        let f = fillet, h = width / 2, ri = innerRadius, ro = outerRadius
        var points = line(from: (ri + f, h), to: (ro - f, h), normal: (0, 1), steps: 4)
        points += arc(r: ro - f, y: h - f, radius: f, from: .pi / 2, to: 0, steps: 10).dropFirst()
        points += line(from: (ro, h - f), to: (ro, -h + f), normal: (1, 0), steps: 8).dropFirst()
        points += arc(r: ro - f, y: -h + f, radius: f, from: 0, to: -.pi / 2, steps: 10).dropFirst()
        points += line(from: (ro - f, -h), to: (ri + f, -h), normal: (0, -1), steps: 4).dropFirst()
        return points
    }

    /// The rounded lips between the shell and the resin — polished metal on the real ring.
    private static var lips: [[ProfilePoint]] {
        let f = fillet, h = width / 2, ri = innerRadius
        return [arc(r: ri + f, y: h - f, radius: f, from: .pi, to: .pi / 2, steps: 8),
                arc(r: ri + f, y: -h + f, radius: f, from: -.pi / 2, to: -.pi, steps: 8)]
    }

    /// The inner face, bottom to top, facing the hole.
    private static var innerBand: [ProfilePoint] {
        let h = width / 2 - fillet
        return line(from: (innerRadius, -h), to: (innerRadius, h), normal: (-1, 0), steps: 6)
    }

    /// Lathes a clockwise profile; triangles wind so the given normals face out.
    private static func lathe(_ profile: [ProfilePoint], segments: Int = 96, radiusOffset: CGFloat = 0) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        let yMin = profile.map(\.y).min() ?? 0
        let yMax = profile.map(\.y).max() ?? 1
        for point in profile {
            for s in 0...segments {
                let a = 2 * CGFloat.pi * CGFloat(s) / CGFloat(segments)
                let c = cos(a), sn = sin(a)
                let r = point.r + radiusOffset
                positions.append(SCNVector3(Float(r * c), Float(point.y), Float(r * sn)))
                normals.append(SCNVector3(Float(point.nr * c), Float(point.ny), Float(point.nr * sn)))
                uvs.append(CGPoint(x: CGFloat(s) / CGFloat(segments), y: (yMax - point.y) / max(0.0001, yMax - yMin)))
            }
        }
        var indices: [Int32] = []
        let row = segments + 1
        for i in 0..<(profile.count - 1) {
            for s in 0..<segments {
                let a = Int32(i * row + s), b = Int32(i * row + s + 1)
                let c = Int32((i + 1) * row + s), d = Int32((i + 1) * row + s + 1)
                indices += [a, b, c, b, d, c]
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                      SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: Textures

    /// The inner face as you see it looking into the ring: the flex board down one arc, the
    /// laser marks down the other, and a metalness map drawn from the same layout so the solder
    /// and the shield can catch the light while the laminate does not.
    ///
    /// u runs around the band, v across it. The charging port sits at u = 0.75 (that is where
    /// `mount(along: 0)` lands), so the board is drawn around it and the marks go opposite.
    static let board = (color: drawInnerFace(metalness: false), metalness: drawInnerFace(metalness: true))

    /// Where the board runs, as a fraction of the way round: a little over half the ring,
    /// centred on the charging port.
    private static let boardArc: ClosedRange<CGFloat> = 0.47...1.03
    /// Where "SMART RING · FC CE · 9" is etched.
    private static let markCentre: CGFloat = 0.24

    private static func drawInnerFace(metalness: Bool) -> UIImage {
        let size = CGSize(width: 2400, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let g = context.cgContext
            // Both passes consume the same random sequence, so the maps line up.
            var seed: UInt32 = 0x9E37_79B9
            func random() -> CGFloat {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return CGFloat(seed >> 8) / CGFloat(1 << 24)
            }
            /// Fills a rect, repeating it across the u seam so the board can wrap past x = 0.
            func fill(_ rect: CGRect, _ color: UIColor, metallic: CGFloat = 0) {
                (metalness ? UIColor(white: metallic, alpha: 1) : color).setFill()
                g.fill(rect)
                if rect.maxX > size.width { g.fill(rect.offsetBy(dx: -size.width, dy: 0)) }
                if rect.minX < 0 { g.fill(rect.offsetBy(dx: size.width, dy: 0)) }
            }
            let solder = UIColor(white: 0.92, alpha: 1)
            let package = UIColor(white: 0.03, alpha: 1)
            // Black, but a shade lighter than the outer band's 0.05 — looking inside the real ring
            // the cavity reads lighter than the polished shell around it, and the parts have to
            // stand out of it rather than disappear into it.
            fill(CGRect(origin: .zero, size: size), UIColor(red: 0.048, green: 0.052, blue: 0.056, alpha: 1))

            // MARK: The flex board
            let boardStart = boardArc.lowerBound * size.width
            let boardEnd = boardArc.upperBound * size.width
            let portX = size.width * 0.75
            fill(CGRect(x: boardStart, y: 0, width: boardEnd - boardStart, height: size.height),
                 UIColor(red: 0.058, green: 0.070, blue: 0.062, alpha: 1))
            // The laminate fades into the shell rather than ending on a hard line.
            for step in 0..<14 {
                let t = CGFloat(step) / 14
                let alpha = 1 - t
                let edge = UIColor(red: 0.052, green: 0.060, blue: 0.056, alpha: alpha * 0.6)
                fill(CGRect(x: boardStart - CGFloat(step) * 5, y: 0, width: 5, height: size.height), edge)
                fill(CGRect(x: boardEnd + CGFloat(step) * 5, y: 0, width: 5, height: size.height), edge)
            }

            let segment = (boardEnd - boardStart) / 7
            for index in 0..<7 {
                let x0 = boardStart + CGFloat(index) * segment
                // Flex joint between the rigid sections.
                fill(CGRect(x: x0, y: 0, width: 7, height: size.height), UIColor(white: 0.028, alpha: 1))
                // Vias in a run along both edges, the way the real board carries them.
                var vx = x0 + 18
                while vx < x0 + segment - 14 {
                    fill(CGRect(x: vx, y: 10, width: 4, height: 4), solder, metallic: 1)
                    fill(CGRect(x: vx, y: size.height - 14, width: 4, height: 4), solder, metallic: 1)
                    vx += 14
                }
                // A column of solder dots.
                let columnX = x0 + 24 + random() * (segment - 48)
                var dy: CGFloat = 40
                while dy < size.height - 40 {
                    fill(CGRect(x: columnX, y: dy, width: 3, height: 3), solder, metallic: 1)
                    dy += 9
                }
                // Passives: pale ceramic bodies with bright end caps, in the loose rows of the
                // photograph — they are what you actually pick out looking inside the ring.
                for _ in 0..<26 {
                    let vertical = random() > 0.5
                    let w: CGFloat = vertical ? 8 : 17, h: CGFloat = vertical ? 17 : 8
                    let rect = CGRect(x: x0 + 18 + random() * (segment - 40),
                                      y: 26 + random() * (size.height - 52 - h), width: w, height: h)
                    // Leave the charging port's seat clear — a 3D part sits there.
                    if abs(rect.midX - portX) < 118 && abs(rect.midY - size.height / 2) < 96 { continue }
                    fill(rect.insetBy(dx: -2, dy: -2), UIColor(white: 0.016, alpha: 1))
                    fill(rect, UIColor(red: 0.80, green: 0.78, blue: 0.74, alpha: 1), metallic: 0.45)
                    if vertical {
                        fill(CGRect(x: rect.minX, y: rect.minY, width: w, height: 3), solder, metallic: 1)
                        fill(CGRect(x: rect.minX, y: rect.maxY - 3, width: w, height: 3), solder, metallic: 1)
                    } else {
                        fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: h), solder, metallic: 1)
                        fill(CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: h), solder, metallic: 1)
                    }
                }
                // Fine solder specks between the parts.
                for _ in 0..<26 {
                    let speck = CGRect(x: x0 + 14 + random() * (segment - 28),
                                       y: 18 + random() * (size.height - 36), width: 3, height: 3)
                    if abs(speck.midX - portX) < 112 && abs(speck.midY - size.height / 2) < 92 { continue }
                    fill(speck, solder, metallic: 1)
                }
            }
            // The two parts you pick out by eye in the photograph, at a fixed place each.
            // A gold-framed die — the sensor front-end, its silicon showing violet-black.
            let die = CGRect(x: portX - 470, y: size.height / 2 - 46, width: 92, height: 92)
            fill(die.insetBy(dx: -3, dy: -3), UIColor(white: 0.014, alpha: 1))
            fill(die, UIColor(red: 0.88, green: 0.72, blue: 0.34, alpha: 1), metallic: 0.95)
            fill(die.insetBy(dx: 15, dy: 15), UIColor(red: 0.13, green: 0.11, blue: 0.19, alpha: 1), metallic: 0.2)
            for lead in 0..<5 {
                let y = die.minY + 16 + CGFloat(lead) * 15
                fill(CGRect(x: die.minX + 4, y: y, width: 9, height: 4), solder, metallic: 1)
                fill(CGRect(x: die.maxX - 13, y: y, width: 9, height: 4), solder, metallic: 1)
            }
            // A shield can / crystal: brushed pale metal.
            let can = CGRect(x: portX - 600, y: size.height / 2 - 60, width: 74, height: 46)
            fill(can.insetBy(dx: -3, dy: -3), UIColor(white: 0.014, alpha: 1))
            fill(can, UIColor(red: 0.82, green: 0.80, blue: 0.76, alpha: 1), metallic: 0.9)
            fill(can.insetBy(dx: 7, dy: 7), UIColor(red: 0.64, green: 0.62, blue: 0.58, alpha: 1), metallic: 0.9)
            // A white part, bright against the laminate.
            let white = CGRect(x: portX - 330, y: size.height / 2 + 6, width: 40, height: 40)
            fill(white.insetBy(dx: -3, dy: -3), UIColor(white: 0.014, alpha: 1))
            fill(white, UIColor(white: 0.93, alpha: 1), metallic: 0.4)
            // A black IC package with pads down both sides.
            let chip = CGRect(x: portX - 250, y: size.height / 2 - 58, width: 76, height: 74)
            fill(chip.insetBy(dx: -3, dy: -3), UIColor(white: 0.12, alpha: 1))
            fill(chip, package)
            var pad = chip.minY + 8
            while pad < chip.maxY - 8 {
                fill(CGRect(x: chip.minX - 7, y: pad, width: 7, height: 4), solder, metallic: 1)
                fill(CGRect(x: chip.maxX, y: pad, width: 7, height: 4), solder, metallic: 1)
                pad += 12
            }

            // The optical window beside the port, dark glass with its two dies.
            let window = CGRect(x: portX + 150, y: size.height / 2 - 52, width: 120, height: 104)
            fill(window, UIColor(white: 0.10, alpha: 1), metallic: 0.2)
            fill(window.insetBy(dx: 8, dy: 8), UIColor(red: 0.020, green: 0.030, blue: 0.026, alpha: 1))

            // MARK: The laser marks — "SMART RING  9  [bin]" over "FC CE", as etched inside.
            let ink = metalness ? UIColor(white: 0.05, alpha: 1) : UIColor(white: 0.97, alpha: 1)
            let centre = markCentre * size.width
            func text(_ string: String, _ pointSize: CGFloat, _ at: CGPoint, tracking: CGFloat = 2) {
                let font = UIFont.systemFont(ofSize: pointSize, weight: .medium)
                let attributed = NSAttributedString(string: string, attributes: [
                    .font: font, .foregroundColor: ink, .kern: tracking,
                ])
                let bounds = attributed.size()
                attributed.draw(at: CGPoint(x: at.x - bounds.width / 2, y: at.y - bounds.height / 2))
            }
            text("SMART RING", 52, CGPoint(x: centre - 90, y: size.height * 0.36))
            text("FC", 30, CGPoint(x: centre - 150, y: size.height * 0.66))
            text("CE", 34, CGPoint(x: centre - 70, y: size.height * 0.65))
            text("9", 58, CGPoint(x: centre + 140, y: size.height * 0.40))
            // The crossed-out wheelie bin.
            ink.setStroke()
            ink.setFill()
            g.setLineWidth(5)
            let bin = CGRect(x: centre + 205, y: size.height * 0.24, width: 62, height: 56)
            g.stroke(CGRect(x: bin.minX + 8, y: bin.minY + 14, width: bin.width - 16, height: bin.height - 22))
            g.fill(CGRect(x: bin.minX + 4, y: bin.minY + 6, width: bin.width - 8, height: 6))
            g.fill(CGRect(x: bin.minX - 2, y: bin.maxY + 6, width: bin.width + 4, height: 7))
            g.move(to: CGPoint(x: bin.minX - 2, y: bin.maxY - 2))
            g.addLine(to: CGPoint(x: bin.maxX + 2, y: bin.minY + 2))
            g.strokePath()
        }
    }

    /// A soft studio environment so the lacquer has something to reflect.
    static let environment: UIImage = {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor, UIColor(white: 0.24, alpha: 1).cgColor,
                          UIColor(white: 0.02, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(white: 1, alpha: 0.9).setFill()
            context.cgContext.fill(CGRect(x: 40, y: 16, width: 38, height: 30))
            context.cgContext.fill(CGRect(x: 172, y: 22, width: 24, height: 22))
        }
    }()

    // MARK: Materials

    private static func shellMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        m.metalness.contents = 0.7
        m.roughness.contents = 0.16
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.04
        return m
    }

    private static func resinMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 1, alpha: 0.02)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.02
        m.transparencyMode = .dualLayer
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }

    private static func circuitMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = board.color
        m.diffuse.mipFilter = .linear
        m.metalness.contents = board.metalness
        m.metalness.mipFilter = .linear
        m.roughness.contents = 0.26
        return m
    }

    private static func metalMaterial(_ color: UIColor = UIColor(white: 0.8, alpha: 1),
                                      roughness: CGFloat = 0.2) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = roughness
        return m
    }

    private static func plasticMaterial(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: white, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.35
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
        /// Tilt and scale.
        let pivot: SCNNode
        /// Turntable, about the ring's own axis.
        let spinner: SCNNode
        let leds: [SCNNode]
        let glow: SCNNode
    }

    /// Puts `node` (built facing +Z, toward the finger) on the board behind the resin, `along`
    /// radians around the band from the sensor and `y` across it.
    private static func mount(_ node: SCNNode, along: Float, y: Float, thickness: CGFloat) -> SCNNode {
        let holder = SCNNode()
        holder.eulerAngles.y = along
        node.position = SCNVector3(0, y, Float(-(innerRadius + boardDepth - thickness / 2)))
        holder.addChildNode(node)
        return holder
    }

    /// The magnetic charging port on the inner face — the round part you see looking inside.
    /// Two concentric contacts: a bright outer annulus and a brass centre, set in a dark seat.
    private static func chargingContact() -> SCNNode {
        let node = SCNNode()
        func add(_ geometry: SCNGeometry, z: Float) {
            let part = SCNNode(geometry: geometry)
            part.eulerAngles.x = .pi / 2  // Y-axis primitives turned to face +Z
            part.position.z = z
            node.addChildNode(part)
        }
        let seat = SCNCylinder(radius: 0.108, height: 0.010)
        seat.materials = [plasticMaterial(white: 0.02)]
        add(seat, z: 0)
        let outer = SCNTorus(ringRadius: 0.084, pipeRadius: 0.016)
        outer.materials = [metalMaterial(UIColor(white: 0.80, alpha: 1), roughness: 0.10)]
        add(outer, z: 0.004)
        let inner = SCNTorus(ringRadius: 0.050, pipeRadius: 0.013)
        inner.materials = [metalMaterial(UIColor(red: 0.76, green: 0.66, blue: 0.46, alpha: 1), roughness: 0.16)]
        add(inner, z: 0.004)
        // The middle is dark, with only a small pip catching the light.
        let well = SCNCylinder(radius: 0.038, height: 0.012)
        well.materials = [plasticMaterial(white: 0.012)]
        add(well, z: 0.003)
        let pip = SCNCylinder(radius: 0.014, height: 0.013)
        pip.materials = [metalMaterial(UIColor(white: 0.72, alpha: 1), roughness: 0.2)]
        add(pip, z: 0.004)
        return node
    }

    static func makeNode() -> Parts {
        let root = SCNNode()

        let shell = lathe(shellProfile)
        shell.materials = [shellMaterial()]
        root.addChildNode(SCNNode(geometry: shell))

        for lip in lips {
            let geometry = lathe(lip)
            geometry.materials = [metalMaterial(UIColor(white: 0.55, alpha: 1), roughness: 0.1)]
            root.addChildNode(SCNNode(geometry: geometry))
        }

        let board = lathe(innerBand, radiusOffset: boardDepth)
        board.materials = [circuitMaterial()]
        root.addChildNode(SCNNode(geometry: board))

        let resin = lathe(innerBand)
        resin.materials = [resinMaterial()]
        let resinNode = SCNNode(geometry: resin)
        resinNode.renderingOrder = 10
        root.addChildNode(resinNode)

        // The charging port faces the camera before the ring spins, with raised parts around it.
        root.addChildNode(mount(chargingContact(), along: 0, y: 0, thickness: 0.024))
        let raised: [(along: Float, y: Float, width: CGFloat, height: CGFloat, depth: CGFloat, material: SCNMaterial)] = [
            (-0.20, 0.04, 0.075, 0.08, 0.012, plasticMaterial(white: 0.04)),
            (-0.33, -0.07, 0.055, 0.055, 0.008, metalMaterial(UIColor(red: 0.62, green: 0.58, blue: 0.5, alpha: 1), roughness: 0.35)),
            (0.19, -0.05, 0.05, 0.045, 0.01, plasticMaterial(white: 0.04)),
            (0.30, 0.06, 0.04, 0.07, 0.01, plasticMaterial(white: 0.05)),
        ]
        for part in raised {
            let box = SCNBox(width: part.width, height: part.height, length: part.depth, chamferRadius: 0.003)
            box.materials = [part.material]
            root.addChildNode(mount(SCNNode(geometry: box), along: part.along, y: part.y, thickness: part.depth))
        }

        // The optical sensor's LEDs: dark dies until a measurement lights them. They sit in the
        // dark window drawn beside the charging port, not on the port itself.
        let green = UIColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)
        let placements: [(along: Float, y: Float, color: UIColor)] = [
            (0.50, 0.055, green), (0.60, -0.055, green),
            (0.55, -0.005, UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)),
        ]
        var leds: [SCNNode] = []
        for placement in placements {
            let die = SCNBox(width: 0.024, height: 0.018, length: 0.006, chamferRadius: 0.002)
            die.materials = [ledMaterial(placement.color)]
            let node = SCNNode(geometry: die)
            root.addChildNode(mount(node, along: placement.along, y: placement.y, thickness: 0.006))
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
        glow.position = SCNVector3(0, 0, Float(-(innerRadius - 0.12)))
        root.addChildNode(glow)

        let spinner = SCNNode()
        spinner.addChildNode(root)
        let pivot = SCNNode()
        pivot.addChildNode(spinner)
        return Parts(pivot: pivot, spinner: spinner, leds: leds, glow: glow)
    }

    // MARK: Scene

    /// One scene plus the nodes that animate. Held by `RingSceneView`.
    final class Live {
        static let idleLED: CGFloat = 0.15

        let scene = SCNScene()
        let camera = SCNNode()
        private let pivot: SCNNode
        private let spinner: SCNNode
        private let leds: [SCNNode]
        private let glow: SCNNode

        init(spin: Bool, tilt: Float = RingModel.defaultTilt, cameraDistance: Float = 4.2,
             spinSeconds: Double = 34, spinAngle: Float = 0) {
            let parts = RingModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            leds = parts.leds
            glow = parts.glow

            scene.background.contents = UIColor.clear
            scene.lightingEnvironment.contents = RingModel.environment
            scene.lightingEnvironment.intensity = 1.6
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(tilt, 0, 0.32)
            // Poses the ring at a fixed point in its turn — the render harness looks at the
            // board on one side and the laser marks on the other.
            spinner.eulerAngles.y = spinAngle
            if spin {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinSeconds)),
                                  forKey: "spin")
            }

            let lights: [(SCNLight.LightType, CGFloat, UIColor, SCNVector3)] = [
                (.directional, 700, .white, SCNVector3(-0.6, 0.5, 0)),
                (.directional, 450, UIColor(red: 0.7, green: 0.82, blue: 1, alpha: 1), SCNVector3(-0.2, -2.3, 0)),
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

        /// Whether a measurement wants the LEDs pulsing, so a find flash can hand back to it.
        private var measuring = false

        func playEntrance() {
            pivot.scale = SCNVector3(0.6, 0.6, 0.6)
            pivot.opacity = 0
            let grow = SCNAction.scale(to: 1, duration: 0.55)
            grow.timingMode = .easeOut
            pivot.runAction(.group([grow, .fadeIn(duration: 0.35)]))
        }

        /// The LEDs breathe and cast a green glow while a measurement runs.
        func setPulsing(_ on: Bool) {
            measuring = on
            pulse(on)
        }

        private func pulse(_ on: Bool) {
            leds.forEach { $0.removeAction(forKey: "pulse") }
            glow.removeAction(forKey: "pulse")
            guard on else {
                leds.forEach { $0.geometry?.firstMaterial?.emission.intensity = Self.idleLED }
                glow.light?.intensity = 0
                return
            }
            let period = 1.0
            let idle = Self.idleLED
            let pulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.geometry?.firstMaterial?.emission.intensity = idle + (2 - idle) * CGFloat(phase)
            }
            leds.forEach { $0.runAction(.repeatForever(pulse), forKey: "pulse") }
            let glowPulse = SCNAction.customAction(duration: period) { node, elapsed in
                let phase = (sin(Double(elapsed) / period * 2 * .pi - .pi / 2) + 1) / 2
                node.light?.intensity = CGFloat(40 * phase)
            }
            glow.runAction(.repeatForever(glowPulse), forKey: "pulse")
        }

        /// "Find ring": a quick hop and a burst of LED light.
        func flash() {
            let hop = SCNAction.sequence([.scale(to: 1.08, duration: 0.12), .scale(to: 1.0, duration: 0.18)])
            pivot.runAction(.repeat(hop, count: 3), forKey: "hop")
            pulse(true)
            // Back to whatever a running measurement wants, not simply off.
            pivot.runAction(.sequence([.wait(duration: 2.0), .run { [weak self] _ in
                guard let self else { return }
                self.pulse(self.measuring)
            }]), forKey: "flash")
        }
    }
}
