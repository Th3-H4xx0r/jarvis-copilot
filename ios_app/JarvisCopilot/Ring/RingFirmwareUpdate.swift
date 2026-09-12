import Foundation

/// Firmware over-the-air update for the R12 family, over the big-data (`0xBC`) channel.
///
/// This is the on-device twin of the app's stock updater (`DfuHandle`) and of
/// `qring-re/fw/patch/ota_flash.py`: the same frame sequence, the same CRC-16/MODBUS, the
/// same per-pocket acks. The ring stages the image in spare flash and only commits after
/// its own magic / model / length checks, so a failed or interrupted transfer leaves the
/// running firmware intact — see `qring-re/fw/patch/README.md` "SAFETY".
///
/// Sequence: `cmd1` start → `cmd2` init `[01][len u32 LE][crc16 u16][bytesum u16]` →
/// `cmd3` data `[seq u16 from 1][≤1024 bytes]` (one per ack) → `cmd4` check → `cmd5` end.
enum RingFirmwareUpdate {

    static let pocket = 1024
    static let magic: UInt32 = 0x81BD_C3E5          // wrapper magic at offset 0
    static let imageID: UInt16 = 0x2793             // Realtek image_id at 0x54
    static let model = Array("RT12_V3.1".utf8)       // memcmp'd on the first chunk
    static let minSize = 0x2800
    static let maxSize = 0x2800 + 0x21851            // receiver's accepted length range

    enum Failure: Error, Equatable {
        case tooShort
        case badMagic
        case sizeOutOfRange(Int)
        case modelMismatch
        case badImageID(UInt16)
        case wrapperChecksum
        case ringRejected(cmd: UInt8, status: UInt8)
        case noAck(cmd: UInt8)

        /// A human-readable reason, for the skill reply and the log.
        var reason: String {
            switch self {
            case .tooShort: return "image is too short to be an R12 image"
            case .badMagic: return "wrong wrapper magic at offset 0 (not an R12 image)"
            case .sizeOutOfRange(let n): return "image size \(n) is outside the ring's accepted range"
            case .modelMismatch: return "image is not for this model (RT12_V3.1 missing)"
            case .badImageID(let id): return String(format: "wrong image_id 0x%04X (want 0x2793)", id)
            case .wrapperChecksum: return "wrapper checksum at 0x0C does not match the image body"
            case .ringRejected(let cmd, let status): return "ring rejected OTA step \(cmd) with status \(status)"
            case .noAck(let cmd): return "no acknowledgement for OTA step \(cmd)"
            }
        }
    }

    /// Everything the ring's own receiver checks before it will accept the image, run here
    /// first so the app refuses a bad file instead of starting a doomed transfer. `nil` = OK.
    static func precondition(_ image: [UInt8]) -> Failure? {
        guard image.count >= 0x56 else { return .tooShort }
        guard u32(image, 0) == magic else { return .badMagic }
        guard (minSize..<maxSize).contains(image.count) else { return .sizeOutOfRange(image.count) }
        guard image.count >= 0x200, containsModel(image) else { return .modelMismatch }
        let id = UInt16(image[0x54]) | (UInt16(image[0x55]) << 8)
        guard id == imageID else { return .badImageID(id) }
        let stored = u32(image, 0x0C)
        let body = image[0x50...].reduce(UInt32(0)) { ($0 &+ UInt32($1)) & 0xFFFF_FFFF }
        guard stored == body else { return .wrapperChecksum }
        return nil
    }

    /// The ordered `(cmd, payload)` steps to send. `sendRawBigData` adds the `0xBC` framing.
    static func steps(for image: [UInt8]) -> [(cmd: UInt8, payload: [UInt8])] {
        let crc = RingProtocol.crc16(image)
        let sum = image.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        var init9: [UInt8] = [0x01]
        init9 += le32(UInt32(image.count))
        init9 += le16(crc)
        init9 += le16(sum)
        var out: [(UInt8, [UInt8])] = [(1, []), (2, init9)]
        var index = 0
        while index * pocket < image.count {
            let slice = Array(image[index * pocket ..< min((index + 1) * pocket, image.count)])
            out.append((3, le16(UInt16(index + 1)) + slice))
            index += 1
        }
        out += [(4, []), (5, [])]
        return out
    }

    static func pocketCount(_ image: [UInt8]) -> Int {
        (image.count + pocket - 1) / pocket
    }

    /// Drives the whole sequence through `send` (one big-data request → its replies),
    /// failing the moment the ring NAKs a step. `progress` gets `(sentPockets, totalPockets)`.
    static func run(image: [UInt8],
                    send: (UInt8, [UInt8]) async throws -> [RingInbound],
                    progress: (Int, Int) -> Void = { _, _ in }) async throws {
        if let bad = precondition(image) { throw bad }
        let plan = steps(for: image)
        let total = pocketCount(image)
        var sent = 0
        for (cmd, payload) in plan {
            let replies = try await send(cmd, payload)
            try checkAck(cmd: cmd, replies: replies)
            if cmd == 3 { sent += 1; progress(sent, total) }
        }
    }

    /// An OTA ack is a `0xBC cmd …` frame whose first payload byte (SDK `data[6]`) is the
    /// status; 0 means OK. A missing reply for a step is itself a failure.
    static func checkAck(cmd: UInt8, replies: [RingInbound]) throws {
        let acks = replies.filter { if case .bigData = $0 { return true } else { return false } }
        guard let ack = acks.last(where: { $0.cmd == cmd }) ?? acks.last else {
            throw Failure.noAck(cmd: cmd)
        }
        let status = ack.payload.first ?? 0xFF
        guard status == 0 else { throw Failure.ringRejected(cmd: cmd, status: status) }
    }

    // MARK: bytes

    private static func containsModel(_ image: [UInt8]) -> Bool {
        let head = Array(image.prefix(0x200))
        guard model.count <= head.count else { return false }
        for start in 0...(head.count - model.count) where Array(head[start ..< start + model.count]) == model {
            return true
        }
        return false
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
