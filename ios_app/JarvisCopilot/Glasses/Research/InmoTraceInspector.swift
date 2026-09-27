import Foundation

struct InmoTracePreview: Codable, Identifiable, Sendable {
    var id: Int
    var byteCount: Int
    var hex: String
}

struct InmoTraceSummary: Codable, Sendable {
    var format: String
    var packetCount: Int?
    var capturedBytes: Int = 0
    var firstPacketAt: Date?
    var lastPacketAt: Date?
    var linkTypes: [UInt32] = []
    var previews: [InmoTracePreview] = []
    var notice: String
}

enum InmoTraceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

/// Reads container headers only. Bytes are not assumed to be INMO messages or plaintext.
/// Bounded previews; complete originals stay on disk for an external packet analyzer.
enum InmoTraceInspector {
    static let allowedExtensions = ["pcap", "cap", "pcapng", "pklg", "btsnoop", "log", "json"]

    static func inspect(_ url: URL) throws -> InmoTraceSummary {
        let reader = try Reader(url)
        defer { try? reader.file.close() }
        let magic = try reader.bytes(4)
        switch Array(magic) {
        case [0xd4, 0xc3, 0xb2, 0xa1]: return try pcap(reader, little: true, nanos: false)
        case [0xa1, 0xb2, 0xc3, 0xd4]: return try pcap(reader, little: false, nanos: false)
        case [0x4d, 0x3c, 0xb2, 0xa1]: return try pcap(reader, little: true, nanos: true)
        case [0xa1, 0xb2, 0x3c, 0x4d]: return try pcap(reader, little: false, nanos: true)
        case [0x0a, 0x0d, 0x0d, 0x0a]:
            try reader.seek(0)
            return try pcapng(reader)
        default:
            try reader.seek(0)
            let prefix = try reader.bytes(Int(min(reader.size, 128)))
            if url.pathExtension.lowercased() == "json", reader.size <= 1_048_576 {
                let data = try Data(contentsOf: url)
                guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      metadata["schema"] as? String == "inmo-rvi-capture/v1" else {
                    throw InmoTraceError.invalid("JSON must be an INMO RVI helper capture manifest.")
                }
                return InmoTraceSummary(format: "Capture metadata", previews: [],
                    notice: "Acquisition metadata from the Mac helper. Preserved as supplied; review the exported JSON for capture status, times, filter, hash, and tcpdump diagnostics.")
            }
            if url.pathExtension.lowercased() == "pklg" {
                return InmoTraceSummary(format: "PacketLogger (opaque)", previews: [preview(0, prefix, Int(reader.size))],
                    notice: "Original preserved. PacketLogger format and packet contents have not been validated or decoded. Open in PacketLogger or Wireshark; no completeness claim.")
            }
            if prefix.starts(with: Data("btsnoop\0".utf8)), reader.size >= 16 {
                return InmoTraceSummary(format: "Bluetooth snoop (opaque)", previews: [preview(0, prefix, Int(reader.size))],
                    notice: "Snoop signature recognized. Original preserved for external Bluetooth analysis; records are not decoded here.")
            }
            throw InmoTraceError.invalid("Unsupported or invalid trace. Choose PCAP, PCAPNG, PacketLogger (.pklg), or a Bluetooth snoop file.")
        }
    }

    private static func preview(_ index: Int, _ bytes: Data, _ count: Int) -> InmoTracePreview {
        InmoTracePreview(id: index, byteCount: count,
                         hex: bytes.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    private static func pcap(_ r: Reader, little: Bool, nanos: Bool) throws -> InmoTraceSummary {
        let header = try r.bytes(20)
        let version = little ? Array(header.prefix(4)) == [2,0,4,0] : Array(header.prefix(4)) == [0,2,0,4]
        guard version else { throw InmoTraceError.invalid("Unsupported PCAP version (expected 2.4).") }
        let snap = Int(u32(header, 12, little))
        var result = InmoTraceSummary(format: "PCAP", packetCount: 0, linkTypes: [u32(header, 16, little)],
            notice: "Container records only. Link-layer bytes may include non-INMO traffic or encrypted payloads. Previews show up to 128 bytes of the first 20 records.")
        while r.position < r.size {
            let record = try r.bytes(16)
            let cap = Int(u32(record, 8, little)), original = Int(u32(record, 12, little))
            let fraction = u32(record, 4, little)
            guard cap <= snap, cap <= original, fraction < (nanos ? 1_000_000_000 : 1_000_000) else {
                throw InmoTraceError.invalid("Invalid PCAP record length or timestamp.")
            }
            let time = Date(timeIntervalSince1970: Double(u32(record, 0, little)) + Double(fraction) / (nanos ? 1e9 : 1e6))
            if result.firstPacketAt == nil { result.firstPacketAt = time }
            result.lastPacketAt = time
            let sample = try r.bytes(min(cap, 128))
            try r.skip(cap - sample.count)
            result.packetCount! += 1
            result.capturedBytes += cap
            if result.previews.count < 20 { result.previews.append(preview(result.packetCount!, sample, cap)) }
        }
        return result
    }

    private static func pcapng(_ r: Reader) throws -> InmoTraceSummary {
        var little = true
        var interfaces = [UInt32]()
        var result = InmoTraceSummary(format: "PCAPNG", packetCount: 0,
            notice: "Container records only. Packet timestamps and directions are not decoded here. Previews show up to 128 bytes of the first 20 records; analyze original in Wireshark.")
        while r.position < r.size {
            let start = r.position
            let header = try r.bytes(12)
            let section = Array(header.prefix(4)) == [0x0a, 0x0d, 0x0d, 0x0a]
            if section {
                switch Array(header[8..<12]) {
                case [0x4d,0x3c,0x2b,0x1a]: little = true
                case [0x1a,0x2b,0x3c,0x4d]: little = false
                default: throw InmoTraceError.invalid("Invalid PCAPNG byte order.")
                }
                interfaces.removeAll()
            }
            let type = u32(header, 0, little), length = Int(u32(header, 4, little))
            guard length >= (section ? 28 : 12), length % 4 == 0,
                  UInt64(length) <= r.size - start else { throw InmoTraceError.invalid("Invalid or truncated PCAPNG block.") }
            var packetLength: Int?
            var packetOffset: UInt64 = 0
            if type == 1 {
                guard length >= 20 else { throw InmoTraceError.invalid("Short PCAPNG interface block.") }
                let link = little ? UInt32(header[8]) | UInt32(header[9]) << 8 : UInt32(header[8]) << 8 | UInt32(header[9])
                interfaces.append(link)
                if !result.linkTypes.contains(link) { result.linkTypes.append(link) }
            } else if type == 6 || type == 2 {
                guard length >= 32 else { throw InmoTraceError.invalid("Short PCAPNG packet block.") }
                let iface = type == 6 ? u32(header, 8, little) : (little ? UInt32(header[8]) | UInt32(header[9]) << 8 : UInt32(header[8]) << 8 | UInt32(header[9]))
                guard Int(iface) < interfaces.count else { throw InmoTraceError.invalid("PCAPNG packet references an unknown interface.") }
                let rest = try r.bytes(16)
                let cap = Int(u32(rest, 8, little)), original = Int(u32(rest, 12, little))
                guard cap <= length - 32, cap <= original else { throw InmoTraceError.invalid("Invalid PCAPNG packet length.") }
                packetLength = cap; packetOffset = start + 28
            } else if type == 3 {
                guard !interfaces.isEmpty, length >= 16 else { throw InmoTraceError.invalid("Invalid PCAPNG simple packet.") }
                // Simple-packet captured length also depends on snaplen; leave this record opaque.
                result.packetCount! += 1
                result.notice += result.notice.contains("Simple packets") ? "" : " Simple packets are counted but their captured byte totals and previews are omitted."
            }
            if let count = packetLength {
                try r.seek(packetOffset)
                let sample = try r.bytes(min(count, 128))
                result.packetCount! += 1; result.capturedBytes += count
                if result.previews.count < 20 { result.previews.append(preview(result.packetCount!, sample, count)) }
            }
            try r.seek(start + UInt64(length) - 4)
            guard u32(try r.bytes(4), 0, little) == UInt32(length) else {
                throw InmoTraceError.invalid("PCAPNG block length trailer does not match.")
            }
        }
        return result
    }

    private static func u32(_ d: Data, _ i: Int, _ little: Bool) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(d[i + $1]) << UInt32((little ? $1 : 3 - $1) * 8) }
    }

    private final class Reader {
        let file: FileHandle
        let size: UInt64
        var position: UInt64 = 0
        init(_ url: URL) throws {
            file = try FileHandle(forReadingFrom: url)
            size = try file.seekToEnd()
            try file.seek(toOffset: 0)
        }
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, UInt64(count) <= size - position else {
                throw InmoTraceError.invalid("Trace ends inside a header or packet. Original file may be incomplete.")
            }
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw InmoTraceError.invalid("Could not read the complete trace record.") }
            position += UInt64(count)
            return data
        }
        func seek(_ offset: UInt64) throws {
            guard offset <= size else { throw InmoTraceError.invalid("Trace offset exceeds file size.") }
            try file.seek(toOffset: offset); position = offset
        }
        func skip(_ count: Int) throws { try seek(position + UInt64(count)) }
    }
}
