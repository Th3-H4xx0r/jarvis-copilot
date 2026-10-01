import Foundation

/// Turns one X5 notification into the frames `RingTransport` routes.
///
/// The ring answers most commands with an ordinary 16-byte checksummed frame, but history and
/// live data arrive differently: a history notification packs as many fixed-length entries as
/// fit (up to 244 bytes) and the store's last one ends with `<op> FF`; the live packet (`09`)
/// and the workout tick (`18`) carry no checksum at all. Each history entry becomes its own
/// frame — opcode plus the entry's bytes after it — and the end marker becomes a frame whose
/// payload is exactly `[FF]`, which is what `isEnd` looks for.
enum X5Frames {
    private static let history: [UInt8: X5HistoryKind] =
        Dictionary(uniqueKeysWithValues: X5HistoryKind.allCases.map { ($0.rawValue, $0) })

    static func split(_ data: Data) -> [(inbound: RingInbound, note: String)] {
        let bytes = [UInt8](data)
        guard let head = bytes.first else { return [] }

        // An ordinary reply. No history notification is ever 16 bytes, so a valid checksum
        // settles it (and a store's delete acknowledgement lands here too).
        if bytes.count == RingProtocol.frameLength,
           RingProtocol.checksum(bytes.dropLast()) == bytes[RingProtocol.frameLength - 1] {
            return [(command(bytes), "")]
        }
        if let kind = history[head] {
            return entries(bytes, kind: kind)
        }
        if head == X5Op.live || head == X5Op.workoutTick {
            return [(.command(cmd: head, isError: false, payload: Array(bytes.dropFirst())), "")]
        }
        // A corrupt reply would otherwise be acted on.
        if bytes.count == RingProtocol.frameLength { return [] }
        return [(.command(cmd: head & 0x7F, isError: false, payload: Array(bytes.dropFirst())), "unparsed")]
    }

    /// The `<op> FF` that closes a history read.
    static func isEnd(_ inbound: RingInbound) -> Bool {
        inbound.payload == [0xFF]
    }

    private static func command(_ bytes: [UInt8]) -> RingInbound {
        let head = bytes[0]
        let isError = head & RingProtocol.errorFlag != 0 && head != X5Op.unbind
        return .command(cmd: isError ? head & 0x7F : head, isError: isError,
                        payload: Array(bytes[1..<(RingProtocol.frameLength - 1)]))
    }

    private static func entries(_ bytes: [UInt8], kind: X5HistoryKind) -> [(inbound: RingInbound, note: String)] {
        let op = kind.rawValue
        let stride = kind.entryLength
        var body = bytes
        var ended = false
        // Only a trailing `op FF` that leaves whole entries behind is the marker: an entry can
        // itself end in those two bytes (55 s, then a reading of 255).
        if body.count >= 2, body[body.count - 2] == op, body[body.count - 1] == 0xFF,
           (body.count - 2) % stride == 0 {
            body.removeLast(2)
            ended = true
        }
        var out: [(inbound: RingInbound, note: String)] = []
        let regular = regularStarts(body, op: op, stride: stride)
        let starts = regular ?? irregularStarts(body, kind: kind)
        let note = regular == nil ? "irregular entry length" : ""
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : body.count
            out.append((.command(cmd: op, isError: false, payload: Array(body[(start + 1)..<end])), note))
        }
        if ended { out.append((.command(cmd: op, isError: false, payload: [0xFF]), "")) }
        return out
    }

    /// Entry offsets when the body is whole entries, each starting with the opcode.
    private static func regularStarts(_ body: [UInt8], op: UInt8, stride: Int) -> [Int]? {
        guard body.count % stride == 0 else { return nil }
        let starts = Array(Swift.stride(from: 0, to: body.count, by: stride))
        return starts.allSatisfy { body[$0] == op } ? starts : nil
    }

    /// Entry offsets found by looking for the opcode followed by a plausible BCD date — for a
    /// firmware that sizes an entry differently from the vendor SDK.
    private static func irregularStarts(_ body: [UInt8], kind: X5HistoryKind) -> [Int] {
        let op = kind.rawValue
        // Day totals carry a one-byte day index then YY MM DD; the rest a two-byte id then six.
        let dateOffset = kind == .dayTotals ? 2 : 3
        let dateLength = kind == .dayTotals ? 3 : 6
        var starts: [Int] = []
        for i in body.indices where body[i] == op && i + dateOffset + dateLength <= body.count {
            let date = body[(i + dateOffset)..<(i + dateOffset + dateLength)]
            if isPlausibleDate(Array(date)), starts.last.map({ i - $0 >= 8 }) ?? true {
                starts.append(i)
            }
        }
        return starts.isEmpty && !body.isEmpty ? [0] : starts
    }

    private static func isPlausibleDate(_ bcd: [UInt8]) -> Bool {
        guard bcd.allSatisfy({ $0 >> 4 <= 9 && $0 & 0x0F <= 9 }) else { return false }
        let values = bcd.map(RingProtocol.fromBCD)
        guard (1...12).contains(values[1]), (1...31).contains(values[2]) else { return false }
        if values.count == 6 { return values[3] < 24 && values[4] < 60 && values[5] < 60 }
        return true
    }
}
