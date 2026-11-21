import Foundation

/// Calibration, as data: walk each OpenRGB zone from its first LED, one fan/ring/strip at a time —
/// where it ends, which part it is (tapped on the model), where its LED 0 sits and which way it runs —
/// and out comes the LED map (server-validated on save).
struct PcCalibration {
    struct ZoneJob: Equatable {
        let controller: Int
        let zone: Int
        let resizable: Bool
        let leds: Int
        /// The most LEDs OpenRGB lets this connector have (resizable ones are measured up to it).
        var max: Int? = nil
    }

    let zones: [ZoneJob]
    private(set) var zoneIndex = 0
    /// LEDs in the current zone (set by scrubbing for resizable zones, else the reported count).
    private(set) var size: Int?
    /// Where the next segment starts.
    private(set) var cursor = 0
    private(set) var segments: [PcSegment] = []
    private(set) var mapped: [PcZone] = []

    init(zones: [ZoneJob]) {
        self.zones = zones
        prepare()
    }

    var current: ZoneJob? { zoneIndex < zones.count ? zones[zoneIndex] : nil }
    var done: Bool { zoneIndex >= zones.count }
    var needsSize: Bool { current != nil && size == nil }
    /// A one-LED connector (a 12 V header): nothing to slide, just "what lit up?".
    var isSingleLED: Bool { !needsSize && (size ?? 0) - cursor <= 1 && current != nil }

    /// While measuring, the connector is resized to this so every LED can be lit.
    var resizeTo: Int? {
        guard let job = current, job.resizable, needsSize else { return nil }
        return Swift.max(1, job.max ?? job.leds)
    }

    /// The LEDs the slider can light now: the whole connector while measuring, else what's left of it.
    var scrubRange: ClosedRange<Int>? {
        guard let job = current else { return nil }
        if needsSize { return 0...(Swift.max(1, job.max ?? job.leds) - 1) }
        guard let size, size - cursor > 1 else { return nil }
        return cursor...(size - 1)
    }

    var missingParts: [PcPart] {
        PcPart.allCases.filter { p in !segments.contains { $0.part == p.rawValue || ($0.also ?? []).contains(p.rawValue) } }
    }

    /// The last LED that still lights while scrubbing → the zone's size.
    mutating func setSize(lastLit: Int) {
        size = max(1, lastLit + 1)
        cursor = 0
    }

    /// Nothing on this zone lit up: leave it out.
    mutating func skipZone() { advance(keep: false) }

    mutating func addSegment(end: Int, part: PcPart, index: Int, ringStartDeg: Double?, clockwise: Bool?,
                             from: String? = nil, also: [PcPart] = []) {
        guard let job = current, let size else { return }
        let last = min(max(end, cursor), size - 1)
        segments.append(PcSegment(part: part.rawValue, index: index, controller: job.controller, zone: job.zone,
                                  start: cursor, count: last - cursor + 1, ringStartDeg: ringStartDeg,
                                  clockwise: clockwise, from: from,
                                  also: also.isEmpty ? nil : also.map(\.rawValue)))
        cursor = last + 1
        if cursor >= size { advance(keep: true) }
    }

    func map() -> PcLedMap { PcLedMap(version: 1, rev: nil, zones: mapped, segments: segments) }

    /// A tap's angle on a fan ring, snapped to the model's nearest LED socket.
    static func snap(degrees: Double, sockets: Int) -> Double {
        let step = 360 / Double(sockets)
        return PcEffects.mod((PcEffects.mod(degrees, 360) / step).rounded() * step, 360)
    }

    private mutating func advance(keep: Bool) {
        if keep, let job = current, let size, segments.contains(where: { $0.controller == job.controller && $0.zone == job.zone }) {
            mapped.append(PcZone(controller: job.controller, zone: job.zone, leds: size))
        }
        zoneIndex += 1
        prepare()
    }

    private mutating func prepare() {
        cursor = 0
        size = nil
        if let job = current, !job.resizable { size = max(1, job.leds) }
    }
}
