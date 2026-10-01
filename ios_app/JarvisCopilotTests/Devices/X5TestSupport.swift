import XCTest
@testable import JarvisCopilot

/// A scripted X5: each write pops the next reply queued for its opcode and delivers it the way
/// the X5 manager does — every notification through `X5Frames.split` into `transport.deliver`.
@MainActor
final class X5FakeLink: RingLink {
    var isLinkReady = true
    var hasBigDataChannel = false
    weak var transport: RingTransport?
    private(set) var sent: [[UInt8]] = []
    private var scripts: [UInt8: [[Data]]] = [:]

    /// Queues one reply — a list of notifications — for the next write of `op`.
    func script(_ op: UInt8, _ notifications: [Data]) {
        scripts[op, default: []].append(notifications)
    }

    /// Opcodes written, in order.
    var sentCommands: [UInt8] { sent.map { $0[0] } }

    /// The 14 payload bytes of every write of `op`.
    func payloads(_ op: UInt8) -> [[UInt8]] {
        sent.filter { $0[0] == op }.map { Array($0[1..<15]) }
    }

    func send(_ data: Data, on channel: RingChannel) {
        let bytes = [UInt8](data)
        sent.append(bytes)
        guard var queue = scripts[bytes[0]], !queue.isEmpty else { return }
        let reply = queue.removeFirst()
        scripts[bytes[0]] = queue
        Task { @MainActor [weak self] in
            for notification in reply { self?.push(notification) }
        }
    }

    /// An unsolicited notification from the ring.
    func push(_ notification: Data) {
        for frame in X5Frames.split(notification) { transport?.deliver(frame.inbound, note: frame.note) }
    }
}

enum X5Bytes {
    static func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// A 16-byte reply: `hex` padded to 15 bytes, checksum appended.
    static func frame(_ hex: String) -> Data {
        var bytes = [UInt8](data(hex))
        bytes += [UInt8](repeating: 0, count: max(0, 15 - bytes.count))
        bytes.append(RingProtocol.checksum(bytes))
        return Data(bytes)
    }

    static func bcd(_ v: Int) -> String { String(format: "%02X", RingProtocol.bcd(v)) }

    /// A single-heart-rate history entry (`55`, 10 bytes).
    static func singleHR(id: Int, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, bpm: Int) -> String {
        [String(format: "55 %02X %02X", id & 0xFF, id >> 8), bcd(y % 100), bcd(mo), bcd(d), bcd(h), bcd(mi), bcd(s),
         String(format: "%02X", bpm)].joined(separator: " ")
    }

    /// Notifications of at most 244 bytes holding `entries`, the last followed by `op FF`.
    static func notifications(_ entries: [String], op: UInt8, end: Bool = true) -> [Data] {
        var out: [Data] = []
        var current: [UInt8] = []
        for entry in entries {
            let bytes = [UInt8](data(entry))
            if current.count + bytes.count > 244 {
                out.append(Data(current))
                current = []
            }
            current += bytes
        }
        if end {
            if current.count + 2 > 244 { out.append(Data(current)); current = [] }
            current += [op, 0xFF]
        }
        if !current.isEmpty { out.append(Data(current)) }
        return out
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
}
