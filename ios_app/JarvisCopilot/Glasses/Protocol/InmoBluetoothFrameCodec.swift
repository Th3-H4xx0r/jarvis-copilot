import Foundation

struct InmoProtocolCounters { var validFrames = 0; var invalidFrames = 0; var expiredAssemblies = 0 }
final class InmoBluetoothFrameCodec {
    private struct Assembly { var fragments: [Int: Data]; var updated: Date; var size: Int }
    private struct Stream { var bytes: Data; var updated: Date }
    private var streams: [String: Stream] = [:]
    private var assemblies: [String: Assembly] = [:]
    private(set) var counters = InmoProtocolCounters()
    static func crc(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data { crc ^= UInt16(byte) << 8; for _ in 0..<8 { crc = (crc & 0x8000 != 0) ? (crc << 1) ^ 0x1021 : crc << 1 } }
        return crc
    }
    static func frames(payload: Data, id: UInt16, maximumFrameLength: Int, source: UInt8 = 3, destination: UInt8 = 1) throws -> [Data] {
        guard maximumFrameLength > 14, payload.count <= InmoWireCodec.maximumMessageSize else { throw InmoProtocolError.malformed("Invalid frame size") }
        let capacity = min(maximumFrameLength - 14, 65535); let count = max(1, (payload.count + capacity - 1) / capacity)
        guard count <= 4096 else { throw InmoProtocolError.malformed("Too many fragments") }
        func word(_ n: Int) -> Data { Data([UInt8((n >> 8) & 255), UInt8(n & 255)]) }
        return (0..<count).map { index in
            let start = index * capacity; let chunk = payload.subdata(in: start..<min(payload.count, start + capacity))
            var frame = Data([0xaa, 0x55]) + word(Int(id)) + word(count) + word(index) + Data([source, destination]) + word(chunk.count) + chunk
            frame += word(Int(crc(frame))); return frame
        }
    }
    func reset() { streams.removeAll(); assemblies.removeAll() }
    func consume(_ data: Data, session: UUID, channel: String, now: Date = Date()) -> [Data] {
        for (key, a) in assemblies where now.timeIntervalSince(a.updated) > 10 { assemblies.removeValue(forKey: key); counters.expiredAssemblies += 1 }
        for (key, stream) in streams where now.timeIntervalSince(stream.updated) > 10 {
            streams.removeValue(forKey: key)
            if !stream.bytes.isEmpty { counters.expiredAssemblies += 1 }
        }
        let streamKey = "\(session)/\(channel)"
        guard streams[streamKey] != nil || streams.count < 128 else { counters.invalidFrames += 1; return [] }
        var buffer = streams[streamKey]?.bytes ?? Data()
        defer {
            if buffer.isEmpty { streams.removeValue(forKey: streamKey) }
            else { streams[streamKey] = Stream(bytes: buffer, updated: now) }
        }
        guard data.count <= InmoWireCodec.maximumMessageSize else { counters.invalidFrames += 1; return [] }
        buffer += data
        if buffer.count > InmoWireCodec.maximumMessageSize + 65549 { buffer.removeAll(); counters.invalidFrames += 1; return [] }
        var output: [Data] = []
        while buffer.count >= 2 {
            let b = Array(buffer)
            if b[0] != 0xaa || b[1] != 0x55 { buffer.removeFirst(); continue }
            guard b.count >= 12 else { break }
            func word(_ index: Int) -> Int { Int(b[index]) << 8 | Int(b[index + 1]) }
            let total = word(4), index = word(6), length = word(10), size = length + 14
            guard total > 0, total <= 4096, index < total else { buffer.removeFirst(2); counters.invalidFrames += 1; continue }
            guard b.count >= size else { break }
            let frame = Data(b[..<size]); buffer.removeFirst(size)
            guard Self.crc(Data(frame.dropLast(2))) == UInt16(word(size - 2)) else { counters.invalidFrames += 1; continue }
            counters.validFrames += 1
            let key = "\(session)/\(channel)/\(b[8])/\(b[9])/\(word(2))/\(total)"
            let chunk = Data(frame.dropFirst(12).dropLast(2))
            var a = assemblies[key] ?? Assembly(fragments: [:], updated: now, size: 0)
            if let old = a.fragments[index] {
                if old != chunk { assemblies.removeValue(forKey: key); counters.invalidFrames += 1 }
                continue
            }
            guard a.size + chunk.count <= InmoWireCodec.maximumMessageSize, assemblies.count < 128 || assemblies[key] != nil else { assemblies.removeValue(forKey: key); counters.invalidFrames += 1; continue }
            a.fragments[index] = chunk; a.size += chunk.count; a.updated = now
            if a.fragments.count == total {
                var payload = Data(); for i in 0..<total { payload += a.fragments[i]! }; output.append(payload); assemblies.removeValue(forKey: key)
            } else { assemblies[key] = a }
        }
        return output
    }
}
