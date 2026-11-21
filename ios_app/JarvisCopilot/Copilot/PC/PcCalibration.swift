import Foundation

/// Calibration probes, newest only: one in flight, and while it's out only the latest position waits
/// (sliding fast queued dozens that arrived seconds late).
@MainActor
final class PcProbeQueue {
    private let send: ([String: Any]) async -> String?
    private var inFlight = false
    private var pending: [String: Any]?
    var onError: ((String) -> Void)?

    init(send: @escaping ([String: Any]) async -> String?) { self.send = send }

    func submit(_ args: [String: Any]) {
        if inFlight { pending = args; return }
        inFlight = true
        Task { await run(args) }
    }

    private func run(_ args: [String: Any]) async {
        var next: [String: Any]? = args
        while let a = next {
            if let e = await send(a) { onError?(e) }
            next = pending
            pending = nil
        }
        inFlight = false
    }
}

/// OpenRGB-style calibration, as data: every connector gets an LED count (a slider), then runs of its
/// LEDs are painted onto parts of the PC. Out comes the LED map (server-validated on save).
struct PcCalibrationBoard {
    struct Run: Equatable {
        var range: ClosedRange<Int>
        var part: PcPart
        var index: Int
        var also: [PcPart]
        var line: [[Double]]? = nil
    }

    struct Connector: Equatable {
        let controller: Int
        let zone: Int
        let name: String
        let max: Int
        let resizable: Bool
        var leds: Int
        var order: String = "rgb"
        var runs: [Run] = []
    }

    var connectors: [Connector]

    mutating func setLEDs(_ c: Int, _ n: Int) {
        guard connectors.indices.contains(c) else { return }
        let k = connectors[c]
        let size = k.resizable ? Swift.max(0, Swift.min(n, k.max)) : k.leds
        connectors[c].leds = size
        connectors[c].runs = k.runs.compactMap { run in
            guard run.range.lowerBound < size else { return nil }
            var r = run
            r.range = run.range.lowerBound...Swift.min(run.range.upperBound, size - 1)
            return r
        }
    }

    mutating func setOrder(_ c: Int, _ order: String) {
        guard connectors.indices.contains(c), Set(order) == Set("rgb"), order.count == 3 else { return }
        connectors[c].order = order
    }

    /// Paints `range` of connector `c` onto a part: what was painted there before gives way, and the same
    /// fan painted elsewhere moves here (the map allows each fan once).
    mutating func assign(_ c: Int, _ range: ClosedRange<Int>, part: PcPart, index: Int, also: [PcPart] = [],
                         line: [[Double]]? = nil) {
        guard connectors.indices.contains(c), connectors[c].leds > 0 else { return }
        let r = Swift.max(0, range.lowerBound)...Swift.min(range.upperBound, connectors[c].leds - 1)
        guard r.lowerBound <= r.upperBound else { return }
        for i in connectors.indices {
            connectors[i].runs.removeAll { $0.part == part && $0.index == index }
        }
        var kept: [Run] = []
        for run in connectors[c].runs {
            if run.range.upperBound < r.lowerBound || run.range.lowerBound > r.upperBound { kept.append(run); continue }
            if run.range.lowerBound < r.lowerBound {
                var left = run; left.range = run.range.lowerBound...(r.lowerBound - 1); kept.append(left)
            } else if run.range.upperBound > r.upperBound {
                var right = run; right.range = (r.upperBound + 1)...run.range.upperBound; kept.append(right)
            }
        }
        kept.append(Run(range: r, part: part, index: index, also: also.filter { $0 != part }, line: line))
        connectors[c].runs = kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func part(_ c: Int, led: Int) -> PcPart? {
        connectors.indices.contains(c) ? connectors[c].runs.first { $0.range.contains(led) }?.part : nil
    }

    func map() -> PcLedMap {
        var zones: [PcZone] = []
        var segments: [PcSegment] = []
        for k in connectors where k.leds > 0 && !k.runs.isEmpty {
            zones.append(PcZone(controller: k.controller, zone: k.zone, leds: k.leds, order: k.order == "rgb" ? nil : k.order))
            for run in k.runs {
                segments.append(PcSegment(part: run.part.rawValue, index: run.index, controller: k.controller, zone: k.zone,
                                          start: run.range.lowerBound, count: run.range.count, ringStartDeg: 0, clockwise: true,
                                          from: run.part == .strip ? "back" : nil,
                                          also: run.also.isEmpty ? nil : run.also.map(\.rawValue), line: run.line))
            }
        }
        return PcLedMap(version: 1, rev: nil, zones: zones, segments: segments)
    }

    var missingParts: [PcPart] {
        let segs = map().segments
        return PcPart.allCases.filter { p in !segs.contains { $0.part == p.rawValue || ($0.also ?? []).contains(p.rawValue) } }
    }
}

enum PcCalibration {
    /// A tap's angle on a fan ring, snapped to the model's nearest LED socket.
    static func snap(degrees: Double, sockets: Int) -> Double {
        let step = 360 / Double(sockets)
        return PcEffects.mod((PcEffects.mod(degrees, 360) / step).rounded() * step, 360)
    }
}
