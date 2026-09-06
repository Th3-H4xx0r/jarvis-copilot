import Foundation
import CoreBluetooth

/// A single ESF551 measurement decoded from VeSync's VsV2 packet envelope.
struct ScaleObservation: Equatable {
    let weightKg: Double
    let impedanceOhms: Double?
    let timestamp: Date
    let isStable: Bool
    let hasImpedance: Bool
    let wireUnit: UInt8
}

/// CoreBluetooth does not promise a one-notification-to-one-protocol-packet mapping.
/// The ESF551 commonly sends a VsV2 packet in 20-byte ATT chunks, while its complete
/// live packet is 22 bytes. The Android app's `gk0.d` reassembles these chunks before
/// decoding; this is the equivalent streaming framer.
struct VsV2FrameAccumulator {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        pending.append(contentsOf: bytes)
        var frames: [[UInt8]] = []

        while true {
            // Discard preceding transport noise, keeping a possible start byte.
            guard let start = pending.firstIndex(of: 0xA5) else {
                pending.removeAll(keepingCapacity: true)
                break
            }
            if start > 0 { pending.removeFirst(start) }
            guard pending.count >= 6 else { break }

            let length = Int(pending[3]) | (Int(pending[4]) << 8)
            let packetLength = length + 6
            // A VsV2 payload includes four command bytes, so any smaller length is
            // corrupt. Cap it so a bad length cannot make us retain arbitrary bytes.
            guard (4...520).contains(length) else {
                pending.removeFirst()
                continue
            }
            guard pending.count >= packetLength else { break }
            frames.append(Array(pending.prefix(packetLength)))
            pending.removeFirst(packetLength)
        }
        return frames
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Reverse-engineered VeSync VsV2 framing and the ESF551 live-reading decoder.
enum ScaleProtocol {
    static let primaryService = CBUUID(string: "FFF0")
    static let primaryWrite = CBUUID(string: "FFF1")
    static let primaryNotify = CBUUID(string: "FFF2")
    static let alternateService = CBUUID(string: "F000FFE0-0451-4000-B000-000000000000")
    static let alternateWrite = CBUUID(string: "F000FFE1-0451-4000-B000-000000000000")
    static let alternateNotify = CBUUID(string: "F000FFE2-0451-4000-B000-000000000000")

    static let liveMeasurementCommand: UInt16 = 0xA161
    static let timeSyncCommand: UInt16 = 0xA081

    /// The stock protocol uses a one-byte complement so the entire packet totals 0xFF.
    static func checksum(_ frame: [UInt8]) -> UInt8 {
        UInt8(truncatingIfNeeded: ~frame.reduce(0) { $0 + Int($1) })
    }

    /// VeSync's `pk0.e.L()`: sends Unix seconds and whole-hour local UTC offset to
    /// the ESF551 immediately after its FFF1 stream is enabled.
    static func makeTimeSyncFrame(date: Date = Date(), timeZone: TimeZone = .current,
                                  sequence: UInt8) -> [UInt8] {
        let seconds = UInt32(max(0, date.timeIntervalSince1970))
        let offsetHours = Int8(timeZone.secondsFromGMT(for: date) / 3600)
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: seconds),
            UInt8(truncatingIfNeeded: seconds >> 8),
            UInt8(truncatingIfNeeded: seconds >> 16),
            UInt8(truncatingIfNeeded: seconds >> 24),
            UInt8(bitPattern: offsetHours),
        ]
        return makeRequest(command: timeSyncCommand, payload: payload, sequence: sequence)
    }

    /// VsV2 request layout from `gk0.e`: A5, flags, sequence, payload+4 length,
    /// complement checksum, channel 1, command LE, subcommand 0, payload.
    static func makeRequest(command: UInt16, payload: [UInt8], sequence: UInt8) -> [UInt8] {
        let length = payload.count + 4
        var frame: [UInt8] = [0xA5, 0x22, sequence,
                              UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
                              0, 1,
                              UInt8(truncatingIfNeeded: command), UInt8(truncatingIfNeeded: command >> 8), 0]
        frame.append(contentsOf: payload)
        frame[5] = checksum(frame)
        return frame
    }

    static func parse(_ frame: [UInt8]) -> ScaleObservation? {
        guard frame.count >= 22,
              frame[0] == 0xA5,
              frame[9] == 0,
              (Int(frame[3]) | (Int(frame[4]) << 8)) + 6 == frame.count,
              frame.reduce(0, { $0 + Int($1) }) & 0xFF == 0xFF,
              littleEndian16(frame, 7) == liveMeasurementCommand
        else { return nil }

        let rawWeight = littleEndian24(frame, 10)
        // ESF551 load cells can hover a few hundred grams above zero after the user
        // steps off. VeSync surfaces this as a zero-weight session-ending event. Keep
        // that event instead of dropping it so the UI can return to its idle pose.
        let weightKg = rawWeight < 1_000 ? 0 : Double(rawWeight) / 1000
        let hasImpedance = weightKg > 0 && frame[20] != 0
        let timestamp = Date(timeIntervalSince1970: TimeInterval(littleEndian32(frame, 15)))
        return ScaleObservation(
            weightKg: weightKg,
            impedanceOhms: hasImpedance ? Double(littleEndian16(frame, 13)) : nil,
            timestamp: timestamp,
            isStable: weightKg > 0 && frame[19] != 0,
            hasImpedance: hasImpedance,
            wireUnit: frame[21]
        )
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndian24(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
    }

    private static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
