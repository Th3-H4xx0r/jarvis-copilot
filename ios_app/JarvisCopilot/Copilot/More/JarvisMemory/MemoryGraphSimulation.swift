import CoreGraphics
import Foundation

/// The memory map's force layout: repulsion between every pair, springs on
/// edges, a gentle pull to the middle, light collision, and "You" pinned at the
/// origin. Velocity-Verlet style with d3's cooling — `alpha` decays every step,
/// so the layout always comes to rest, and once it has, `step()` does nothing.
///
/// Battery: the view only steps this while the map is on screen and the app is
/// in front, and stops its TimelineView as soon as `isSettled` flips. n ≤ 80, so
/// the O(n²) pair loop is ~3k pairs a step.
struct MemoryGraphSimulation {
    /// The test's budget: a 40-node graph rests well inside this.
    static let maxSteps = 600
    /// Total kinetic energy (pt²/step²) under which motion is invisible.
    static let settleEnergy = 0.1
    /// Past this many steps since the last wake it stops regardless.
    static let hardStop = 1_000

    static let alphaMin = 0.002
    static let alphaDecay = 1 - pow(alphaMin, 1.0 / 300)
    /// Fraction of velocity lost per step.
    static let velocityDecay = 0.4
    static let repulsion = 260.0
    static let linkLength = 64.0
    static let gravity = 0.05
    static let collidePadding = 6.0
    static let distanceMax = 700.0

    private(set) var alpha = 1.0
    private(set) var kineticEnergy = 0.0
    private(set) var isSettled = true
    private var stepsSinceWake = 0

    private var ids: [String] = []
    private var index: [String: Int] = [:]
    private var px: [Double] = [], py: [Double] = []
    private var vx: [Double] = [], vy: [Double] = []
    private var radius: [Double] = []
    private var fixedIndex: Int?
    private struct Link { var s: Int, t: Int, length: Double, strength: Double, bias: Double }
    private var links: [Link] = []

    init() {}

    var nodeCount: Int { ids.count }

    func position(_ id: String) -> CGPoint? {
        guard let i = index[id] else { return nil }
        return CGPoint(x: px[i], y: py[i])
    }

    func radius(_ id: String) -> Double? { index[id].map { radius[$0] } }

    mutating func setPosition(_ id: String, _ p: CGPoint) {
        guard let i = index[id], i != fixedIndex else { return }
        px[i] = p.x; py[i] = p.y
        vx[i] = 0; vy[i] = 0
    }

    /// Wake the layout (new nodes, a removed node, a fresh graph).
    mutating func wake(_ to: Double) {
        alpha = max(alpha, to)
        isSettled = ids.count <= 1
        stepsSinceWake = 0
    }

    /// Bring the bodies in line with the graph: new nodes start beside a placed
    /// neighbour (or on a spiral round the middle), gone ones leave, everyone
    /// else keeps their place.
    mutating func sync(with graph: MemoryGraph) {
        let wanted = graph.nodeIDs
        let wantedSet = Set(wanted)
        let fresh = ids.isEmpty
        let removed = ids.contains { !wantedSet.contains($0) }
        var added: [String] = []

        var nx: [Double] = [], ny: [Double] = [], nvx: [Double] = [], nvy: [Double] = []
        var placed: [String: Int] = [:]
        for id in wanted {
            if let i = index[id] {
                placed[id] = nx.count
                nx.append(px[i]); ny.append(py[i]); nvx.append(vx[i]); nvy.append(vy[i])
            }
        }
        var order = wanted.filter { placed[$0] != nil }
        let neighbours = Dictionary(grouping: graph.edges.flatMap { [($0.a, $0.b), ($0.b, $0.a)] },
                                    by: \.0).mapValues { $0.map(\.1) }
        var spiral = order.count
        for id in wanted where placed[id] == nil {
            let p: (Double, Double)
            if id == MemoryGraph.meID {
                p = (0, 0)
            } else if let anchor = neighbours[id]?.compactMap({ placed[$0] }).first {
                let angle = Self.angle(for: id)
                p = (nx[anchor] + 34 * cos(angle), ny[anchor] + 34 * sin(angle))
            } else {
                let r = 30 * (0.5 + Double(spiral)).squareRoot()
                let a = Double(spiral) * Double.pi * (3 - 5.0.squareRoot())
                p = (r * cos(a), r * sin(a))
                spiral += 1
            }
            placed[id] = nx.count
            nx.append(p.0); ny.append(p.1); nvx.append(0); nvy.append(0)
            order.append(id)
            added.append(id)
        }
        // Keep the graph's order so drawing is stable.
        let final = wanted
        px = final.map { nx[placed[$0]!] }
        py = final.map { ny[placed[$0]!] }
        vx = final.map { nvx[placed[$0]!] }
        vy = final.map { nvy[placed[$0]!] }
        ids = final
        index = Dictionary(uniqueKeysWithValues: final.enumerated().map { ($1, $0) })
        fixedIndex = index[MemoryGraph.meID]
        if let f = fixedIndex { px[f] = 0; py[f] = 0; vx[f] = 0; vy[f] = 0 }

        let maxWeight = graph.maxWeight
        radius = final.map { id in
            id == MemoryGraph.meID ? MemoryGraphStyle.meRadius
                : MemoryGraphStyle.radius(weight: graph.node(id)?.weight ?? 0, maxWeight: maxWeight)
        }

        var degree = [Int](repeating: 0, count: final.count)
        let pairs: [(Int, Int)] = graph.edges.compactMap { e in
            guard let s = index[e.a], let t = index[e.b] else { return nil }
            return (s, t)
        }
        for (s, t) in pairs { degree[s] += 1; degree[t] += 1 }
        links = pairs.map { s, t in
            Link(s: s, t: t,
                 length: Self.linkLength + radius[s] + radius[t],
                 strength: 1 / Double(max(1, min(degree[s], degree[t]))),
                 bias: Double(degree[s]) / Double(max(1, degree[s] + degree[t])))
        }

        if fresh && !final.isEmpty {
            alpha = 1
            wake(1)
        } else if !added.isEmpty {
            wake(0.6)
        } else if removed {
            wake(0.25)
        }
    }

    /// Step until settled or `steps` run out.
    mutating func run(steps: Int) {
        var n = 0
        while n < steps, !isSettled {
            step()
            n += 1
        }
    }

    /// One tick. Answers the kinetic energy after it (0 once settled).
    @discardableResult
    mutating func step() -> Double {
        guard !isSettled else { return 0 }
        let n = ids.count
        alpha += (0 - alpha) * Self.alphaDecay
        stepsSinceWake += 1

        // Springs (d3's link force: positions + velocities, biased by degree).
        for link in links {
            var dx = px[link.t] + vx[link.t] - px[link.s] - vx[link.s]
            var dy = py[link.t] + vy[link.t] - py[link.s] - vy[link.s]
            if dx == 0 && dy == 0 { dx = Self.jiggle(link.s, link.t); dy = Self.jiggle(link.t, link.s) }
            let l = (dx * dx + dy * dy).squareRoot()
            let k = (l - link.length) / l * alpha * link.strength
            dx *= k; dy *= k
            vx[link.t] -= dx * link.bias; vy[link.t] -= dy * link.bias
            vx[link.s] += dx * (1 - link.bias); vy[link.s] += dy * (1 - link.bias)
        }

        // Repulsion + collision, every pair.
        let maxD2 = Self.distanceMax * Self.distanceMax
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var dx = px[j] - px[i], dy = py[j] - py[i]
                var d2 = dx * dx + dy * dy
                if d2 < 1e-6 {
                    dx = Self.jiggle(i, j); dy = Self.jiggle(j, i)
                    d2 = dx * dx + dy * dy
                }
                if d2 > maxD2 { continue }
                let l2 = max(d2, 1)
                let w = Self.repulsion * alpha / l2
                vx[i] -= dx * w; vy[i] -= dy * w
                vx[j] += dx * w; vy[j] += dy * w

                let reach = radius[i] + radius[j] + Self.collidePadding
                if d2 < reach * reach {
                    let d = d2.squareRoot()
                    let push = (reach - d) / d * 0.35
                    vx[i] -= dx * push; vy[i] -= dy * push
                    vx[j] += dx * push; vy[j] += dy * push
                }
            }
        }

        // Pull toward the middle, then integrate.
        var energy = 0.0
        let keep = 1 - Self.velocityDecay
        for i in 0..<n {
            if i == fixedIndex { vx[i] = 0; vy[i] = 0; px[i] = 0; py[i] = 0; continue }
            vx[i] -= px[i] * Self.gravity * alpha
            vy[i] -= py[i] * Self.gravity * alpha
            vx[i] *= keep; vy[i] *= keep
            px[i] += vx[i]; py[i] += vy[i]
            energy += 0.5 * (vx[i] * vx[i] + vy[i] * vy[i])
        }
        kineticEnergy = energy

        if (alpha < 0.1 && energy < Self.settleEnergy) || alpha < Self.alphaMin
            || stepsSinceWake >= Self.hardStop {
            settle()
        }
        return energy
    }

    private mutating func settle() {
        isSettled = true
        for i in vx.indices { vx[i] = 0; vy[i] = 0 }
        kineticEnergy = 0
    }

    /// A stable direction per id, so a new node always sprouts the same way.
    private static func angle(for id: String) -> Double {
        let h = UInt(bitPattern: MoreJSON.stableHash(id))
        return Double(h % 3600) / 3600 * 2 * Double.pi
    }

    /// A tiny deterministic nudge for bodies on the same spot.
    private static func jiggle(_ a: Int, _ b: Int) -> Double {
        (Double((a &* 31 &+ b &* 17) % 7) - 3) * 1e-3 + 1e-4
    }
}

// MARK: - Drawing geometry

/// Sizes the canvas uses (and the layout, for collision and spring lengths).
enum MemoryGraphStyle {
    static let minRadius = 6.0
    static let maxRadius = 24.0
    static let meRadius = 20.0

    /// sqrt scaling: area grows with the number of memories.
    static func radius(weight: Int, maxWeight: Int) -> Double {
        guard maxWeight > 0, weight > 0 else { return minRadius }
        let f = min(1, (Double(weight) / Double(maxWeight)).squareRoot())
        return minRadius + (maxRadius - minRadius) * f
    }
}

/// World ↔ screen. The world origin (You) sits at the view's middle, shifted by
/// the pan and scaled by the zoom.
struct MemoryGraphViewport: Equatable {
    var size: CGSize
    var pan: CGSize
    var zoom: CGFloat

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + size.width / 2 + pan.width, y: p.y * zoom + size.height / 2 + pan.height)
    }

    func toWorld(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - size.width / 2 - pan.width) / zoom, y: (s.y - size.height / 2 - pan.height) / zoom)
    }
}

enum MemoryGraphHitTest {
    /// Extra finger room around a node, in screen points.
    static let slop: CGFloat = 10

    /// The node under a tap: the nearest one whose circle (plus slop) holds it.
    static func node(at screen: CGPoint, graph: MemoryGraph, sim: MemoryGraphSimulation,
                     viewport: MemoryGraphViewport) -> String? {
        let w = viewport.toWorld(screen)
        var best: (id: String, d: CGFloat)?
        for id in graph.nodeIDs {
            guard let p = sim.position(id), let r = sim.radius(id) else { continue }
            let d = hypot(p.x - w.x, p.y - w.y)
            guard d <= CGFloat(r) + slop / viewport.zoom else { continue }
            if best == nil || d < best!.d { best = (id, d) }
        }
        return best?.id
    }
}
