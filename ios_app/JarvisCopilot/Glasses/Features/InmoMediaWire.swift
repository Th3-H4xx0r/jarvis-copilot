import Foundation
import CryptoKit

struct InmoMediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// TCP has a different header from the Bluetooth channel. IDs may change per chunk.
struct InmoMediaFrame {
    var id: UInt8 = 0
    var total: Int = 1
    var index: Int = 0
    var main: UInt8 = 0
    var sub: UInt8 = 0
    var payload = Data()

    static func crc(_ data: Data) -> UInt16 {
        var result: UInt16 = 0xffff
        for byte in data {
            result ^= UInt16(byte) << 8
            for _ in 0..<8 { result = result & 0x8000 != 0 ? (result &<< 1) ^ 0x1021 : result &<< 1 }
        }
        return result
    }
    func encoded() throws -> Data {
        guard (1...65535).contains(total), (0..<total).contains(index), payload.count <= 8192 else {
            throw InmoMediaError(message: "Invalid media frame dimensions.")
        }
        var bytes = Data([0xaa, 0x55, id, UInt8(total >> 8), UInt8(total & 255), UInt8(index >> 8), UInt8(index & 255), main, sub, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        bytes.append(payload)
        let checksum = Self.crc(bytes)
        bytes.append(contentsOf: [UInt8(checksum >> 8), UInt8(checksum & 255)])
        return bytes
    }
}

struct InmoMediaFrameParser {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [InmoMediaFrame] {
        guard buffer.count + data.count <= 1024 * 1024 else { throw InmoMediaError(message: "Media receive buffer exceeded its limit.") }
        buffer.append(data)
        var frames: [InmoMediaFrame] = []
        while buffer.count >= 11 {
            let b = [UInt8](buffer.prefix(11))
            guard b[0] == 0xaa, b[1] == 0x55 else { throw InmoMediaError(message: "Invalid media frame header.") }
            let length = Int(b[9]) << 8 | Int(b[10])
            guard length <= 8192 else { throw InmoMediaError(message: "Media chunk is larger than the supported protocol limit.") }
            guard buffer.count >= length + 13 else { break }
            let raw = Data(buffer.prefix(length + 13))
            let tail = [UInt8](raw.suffix(2))
            guard InmoMediaFrame.crc(Data(raw.dropLast(2))) == UInt16(tail[0]) << 8 | UInt16(tail[1]) else {
                throw InmoMediaError(message: "Media checksum failed. Restart this download.")
            }
            let total = Int(b[3]) << 8 | Int(b[4]), index = Int(b[5]) << 8 | Int(b[6])
            guard total > 0, index < total else { throw InmoMediaError(message: "Invalid media chunk sequence.") }
            frames.append(InmoMediaFrame(id: b[2], total: total, index: index, main: b[7], sub: b[8], payload: Data(raw.dropFirst(11).prefix(length))))
            buffer = Data(buffer.dropFirst(length + 13))
        }
        return frames
    }
}

struct InmoMediaItem: Identifiable, Equatable {
    let name: String
    let directory: String
    let size: Int
    var id: String { directory + "\\" + name }
    var group: String { (name as NSString).deletingPathExtension }
    var remotePath: String { directory.hasSuffix("\\") ? directory + name : id }
    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"), !name.contains(".."),
              !name.unicodeScalars.contains(where: { $0.value < 32 }),
              directory.hasPrefix("D:\\"), !directory.contains(".."), !directory.contains("/"),
              !directory.unicodeScalars.contains(where: { $0.value < 32 }), directory.utf8.count < 512,
              size > 0, size <= 65535 * 8192 else { throw InmoMediaError(message: "The glasses supplied an unsupported media path or size.") }
    }
}

/// Writes ordered TCP chunks directly to disk. Duplicate data must match exactly.
final class InmoMediaFileSink {
    let item: InmoMediaItem
    let temporaryURL: URL
    private let handle: FileHandle
    private var total: Int?
    private var next = 0
    private var hasher = Insecure.MD5()
    private(set) var bytesWritten = 0
    private(set) var committed = false
    init(item: InmoMediaItem, directory: URL) throws {
        try item.validate()
        self.item = item
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURL = directory.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else { throw InmoMediaError(message: "Could not create the media download.") }
        handle = try FileHandle(forUpdating: temporaryURL)
    }
    deinit { try? handle.close(); if !committed { try? FileManager.default.removeItem(at: temporaryURL) } }
    var complete: Bool { total == next && bytesWritten == item.size }
    func append(_ frame: InmoMediaFrame) throws {
        guard frame.main == 0, frame.sub == 0, frame.total == (item.size + 8191) / 8192,
              total == nil || total == frame.total else { throw InmoMediaError(message: "Media chunk count does not match its inventory.") }
        total = frame.total
        let expected = min(8192, item.size - frame.index * 8192)
        guard frame.payload.count == expected else { throw InmoMediaError(message: "Media chunk size does not match its inventory.") }
        if frame.index < next {
            try handle.seek(toOffset: UInt64(frame.index * 8192))
            let old = try handle.read(upToCount: expected)
            try handle.seekToEnd()
            guard old == frame.payload else { throw InmoMediaError(message: "Conflicting duplicate media chunk.") }
            return
        }
        guard frame.index == next else { throw InmoMediaError(message: "Missing or out-of-order media chunk. Restart this download.") }
        try handle.write(contentsOf: frame.payload)
        hasher.update(data: frame.payload)
        bytesWritten += frame.payload.count
        next += 1
    }
    func checksum() throws -> Data {
        guard complete else { throw InmoMediaError(message: "Media file is incomplete.") }
        return Data(hasher.finalize())
    }
    func publish(to directory: URL) throws -> URL {
        guard complete else { throw InmoMediaError(message: "Cannot export an incomplete media file.") }
        try handle.synchronize()
        try handle.close()
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + item.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        committed = true
        return destination
    }
}
