import Foundation

/// One controller's outgoing frames, paced like Magic Lantern: discrete commands leave in order,
/// a colour-type frame (RGB, temperature, white, music) replaces any colour still waiting and at
/// most one leaves every 100 ms, so a dragged colour wheel sends its latest value ten times a second.
struct MelkWriteQueue {
    enum Kind {
        /// RGB / temperature / white / music: coalesced, ≤ 10 Hz.
        case color
        /// Power, effect, scene, mic, pin order, LED count: sent in order, and they drop a colour
        /// still waiting (it would land after them and undo them).
        case replacesColor
        /// Brightness, speed, time, timers: in order, the colour left alone.
        case other
    }

    static let colorInterval: TimeInterval = 0.1

    private(set) var discrete: [Data] = []
    private(set) var pendingColor: Data?
    private var lastColorSent = Date.distantPast

    var isEmpty: Bool { discrete.isEmpty && pendingColor == nil }

    mutating func push(_ frame: Data, kind: Kind) {
        switch kind {
        case .color:
            pendingColor = frame
        case .replacesColor:
            pendingColor = nil
            discrete.append(frame)
        case .other:
            discrete.append(frame)
        }
    }

    /// The next frame to write now, if any.
    mutating func next(now: Date) -> Data? {
        // A colour that's due goes first, as the app flushes its colour buffer before brightness/speed.
        if let color = pendingColor, now.timeIntervalSince(lastColorSent) >= Self.colorInterval {
            pendingColor = nil
            lastColorSent = now
            return color
        }
        if !discrete.isEmpty { return discrete.removeFirst() }
        return nil
    }

    /// Seconds until the waiting colour may go, when nothing else is queued.
    func wait(now: Date) -> TimeInterval? {
        guard discrete.isEmpty, pendingColor != nil else { return nil }
        // (with frames queued, `next` returns one now)
        return max(0, Self.colorInterval - now.timeIntervalSince(lastColorSent))
    }
}
