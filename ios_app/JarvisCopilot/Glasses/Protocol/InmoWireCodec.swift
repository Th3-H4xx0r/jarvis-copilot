import Foundation

enum InmoProtocolError: Error, LocalizedError {
    case malformed(String), unavailable(String), timedOut, cancelled
    var errorDescription: String? {
        switch self { case .malformed(let s), .unavailable(let s): return s
        case .timedOut: return "Glasses did not respond before the deadline."
        case .cancelled: return "Glasses operation was cancelled." }
    }
}
struct InmoWireField {
    let number: Int
    let wireType: Int
    var varint: UInt64? = nil
    var bytes: Data? = nil
    var fixed: UInt64? = nil
    func nested() throws -> [InmoWireField] { try InmoWireCodec.decode(bytes ?? Data()) }
}
extension Array where Element == InmoWireField {
    func firstField(_ number: Int) -> InmoWireField? { last { $0.number == number } }
}
enum InmoWireCodec {
    static let maximumMessageSize = 1_048_576
    static func varint(_ value: UInt64) -> Data {
        var v = value; var b = Data()
        repeat { let low = UInt8(v & 127); v >>= 7; b.append(low | (v == 0 ? 0 : 128)) } while v != 0
        return b
    }
    static func uint(_ field: Int, _ value: UInt64, includeZero: Bool = false) -> Data {
        guard value != 0 || includeZero else { return Data() }
        return varint(UInt64(field << 3)) + varint(value)
    }
    static func signed(_ field: Int, _ value: Int64) -> Data { uint(field, UInt64(bitPattern: value)) }
    static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func float(_ field: Int, _ value: Float) -> Data {
        let v = value.bitPattern
        return varint(UInt64(field << 3 | 5)) + Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) })
    }
    static func decode(_ data: Data) throws -> [InmoWireField] {
        guard data.count <= maximumMessageSize else { throw InmoProtocolError.malformed("Message exceeds limit") }
        let b = Array(data); var i = 0; var fields: [InmoWireField] = []
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in 0..<10 {
                guard i < b.count else { throw InmoProtocolError.malformed("Truncated varint") }
                let c = b[i]; i += 1
                if shift == 9 && c > 1 { throw InmoProtocolError.malformed("Overflowing varint") }
                value |= UInt64(c & 127) << (shift * 7)
                if c < 128 { return value }
            }
            throw InmoProtocolError.malformed("Oversized varint")
        }
        while i < b.count {
            guard fields.count < 16_384 else { throw InmoProtocolError.malformed("Too many fields") }
            let tag = try read(); let n = Int(tag >> 3); let wire = Int(tag & 7)
            guard n > 0 && n <= 536_870_911 else { throw InmoProtocolError.malformed("Invalid field tag") }
            var f = InmoWireField(number: n, wireType: wire)
            switch wire {
            case 0: f.varint = try read()
            case 2:
                let size = try read(); guard size <= UInt64(b.count - i) else { throw InmoProtocolError.malformed("Truncated bytes") }
                let end = i + Int(size); f.bytes = Data(b[i..<end]); i = end
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard b.count - i >= size else { throw InmoProtocolError.malformed("Truncated fixed field") }
                f.fixed = (0..<size).reduce(UInt64(0)) { $0 | UInt64(b[i + $1]) << ($1 * 8) }; i += size
            default: throw InmoProtocolError.malformed("Unsupported protobuf wire type")
            }
            fields.append(f)
        }
        return fields
    }
}
