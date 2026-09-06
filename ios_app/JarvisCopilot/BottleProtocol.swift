import Foundation

/// Protocol for the VSITOO S1 Pro / S1 Lite bottle. See PROTOCOL.md for where each
/// opcode was recovered from in the decompiled app.
enum BottleProtocol {
    static let serviceUUID = "0000A300-0000-1000-8000-00805F9B34FB"
    static let writeUUID   = "0000A301-0000-1000-8000-00805F9B34FB"
    static let notifyUUID  = "0000A303-0000-1000-8000-00805F9B34FB"

    /// The bottle advertises as `VSITOO-S1-Pro…` / `VSITOO-S1-Lite…`.
    static let namePrefixes = ["VSITOO-S1-Pro", "VSITOO-S1-Lite"]

    /// `BottleModel` is traced from an S1 Pro specifically, so it is only an honest
    /// depiction of that device — everything else falls back to a generic icon.
    static func hasModel(forName name: String) -> Bool {
        name.hasPrefix("VSITOO-S1-Pro")
    }

    /// OUI prefixes the app searches for inside the `10` response to find the MAC.
    static let macPrefixes: [[UInt8]] = [[0xA4, 0xC1], [0xA4, 0xB1], [0x4A, 0x4D]]
}

// MARK: - Commands

enum UVIntensity: UInt8, CaseIterable, Identifiable {
    case normal = 0x00
    case strong = 0x01

    var id: UInt8 { rawValue }
    var label: String { self == .normal ? "Normal" : "Strong" }
}

/// Display preference only. The stock app keeps this app-side too — there is no
/// opcode for it; the bottle always reports °C in the `07` frame.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit

    var id: String { rawValue }
    var label: String { self == .celsius ? "°C" : "°F" }
}

/// One entry in a reminder / auto-sterilise schedule.
struct TimeSlot: Equatable {
    var hour: UInt8
    var minute: UInt8
    var isOn: Bool

    var text: String { String(format: "%02d:%02d", hour, minute) }
}

enum BottleCommand: Identifiable {
    // Queries
    case status
    case version
    case macAddress
    case reminderListPart1
    case reminderListPart2
    case autoSteriliseTimes

    // Settings
    case setClock(Date)
    case setScreenSeconds(UInt8)
    case reminderMaster(Bool)
    case sterilise(Bool)
    case autoSterilise(Bool)
    case touchLock(Bool)
    case uvIntensity(UVIntensity)
    case dailyAutoReset(Bool)
    case aiSelfCleanPermanent(Bool)
    case aiSelfCleanTimed(on: Bool, seconds: UInt32)
    case setAutoSteriliseTimes([TimeSlot])

    /// Escape hatch for poking at undocumented opcodes.
    case raw(Data)

    var id: String { hex }

    var bytes: Data {
        switch self {
        case .status:               return Data([0x07])
        case .version:              return Data([0x0B])
        case .macAddress:           return Data([0x10])
        case .reminderListPart1:    return Data([0x05])
        case .reminderListPart2:    return Data([0x06])
        case .autoSteriliseTimes:   return Data([0x15])

        case .setClock(let date):
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            return Data([0x02, UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)])

        case .setScreenSeconds(let s):      return Data([0x03, s])
        case .reminderMaster(let on):       return Data([0x01, on ? 1 : 0])
        case .sterilise(let on):            return Data([0x0E, on ? 1 : 0])
        case .autoSterilise(let on):        return Data([0x0D, on ? 1 : 0])
        case .touchLock(let on):            return Data([0x0F, on ? 1 : 0])
        case .uvIntensity(let i):           return Data([0x11, i.rawValue])
        case .dailyAutoReset(let on):       return Data([0x14, on ? 1 : 0])
        case .aiSelfCleanPermanent(let on): return Data([0x18, on ? 1 : 0])

        case .aiSelfCleanTimed(let on, let seconds):
            var d = Data([0x17, on ? 1 : 0])
            d.append(contentsOf: [
                UInt8((seconds >> 24) & 0xFF), UInt8((seconds >> 16) & 0xFF),
                UInt8((seconds >> 8) & 0xFF),  UInt8(seconds & 0xFF),
            ])
            return d

        case .setAutoSteriliseTimes(let slots):
            return Data([0x12]) + BottleProtocol.encodeTimeSlots(slots)

        case .raw(let d):
            return d
        }
    }

    /// The opcode the bottle echoes back. Used to match a reply to its request.
    var opcode: UInt8 { bytes.first ?? 0 }

    /// Read-only commands. The real app follows every *state-changing* command with a
    /// single status read (`_triggerUiActionEndFlow`) and otherwise sends nothing at all,
    /// so queries must not trigger another query or the link never goes idle.
    var isQuery: Bool {
        switch self {
        case .status, .version, .macAddress,
             .reminderListPart1, .reminderListPart2, .autoSteriliseTimes:
            return true
        default:
            return false
        }
    }

    var hex: String { bytes.hexString }

    var label: String {
        switch self {
        case .status:                     return "Read status"
        case .version:                    return "Read version"
        case .macAddress:                 return "Read MAC"
        case .reminderListPart1:          return "Read reminders 1"
        case .reminderListPart2:          return "Read reminders 2"
        case .autoSteriliseTimes:         return "Read auto-clean times"
        case .setClock:                   return "Sync clock"
        case .setScreenSeconds(let s):    return "Screen \(s)s"
        case .reminderMaster(let on):     return "Reminders \(on ? "on" : "off")"
        case .sterilise(let on):          return on ? "Sterilise now" : "Stop sterilising"
        case .autoSterilise(let on):      return "Auto-sterilise \(on ? "on" : "off")"
        case .touchLock(let on):          return "Touch lock \(on ? "on" : "off")"
        case .uvIntensity(let i):         return "UV \(i.label)"
        case .dailyAutoReset(let o):      return "Daily auto-reset \(o ? "on" : "off")"
        case .aiSelfCleanPermanent(let o): return "AI clean \(o ? "always" : "off")"
        case .aiSelfCleanTimed(_, let s): return "AI clean \(s)s"
        case .setAutoSteriliseTimes:      return "Set auto-clean times"
        case .raw:                        return "Raw"
        }
    }
}

extension BottleProtocol {
    /// mask byte + 8 × (hour, minute), unused slots padded with 0xFF.
    static func encodeTimeSlots(_ slots: [TimeSlot]) -> Data {
        var mask: UInt8 = 0
        var body = Data()
        for (i, slot) in slots.prefix(8).enumerated() {
            if slot.isOn { mask |= (1 << UInt8(i)) }
            body.append(contentsOf: [slot.hour, slot.minute])
        }
        while body.count < 16 { body.append(0xFF) }
        return Data([mask]) + body
    }

    /// Inverse of `encodeTimeSlots`, applied to a payload that excludes the opcode.
    static func decodeTimeSlots(_ payload: Data) -> [TimeSlot] {
        guard let mask = payload.first else { return [] }
        var out: [TimeSlot] = []
        let body = payload.dropFirst()
        for i in 0..<8 {
            let base = body.startIndex + i * 2
            guard base + 1 < body.endIndex else { break }
            let h = body[base], m = body[base + 1]
            guard h <= 23, m <= 59 else { break }
            out.append(TimeSlot(hour: h, minute: m, isOn: (mask >> UInt8(i)) & 1 == 1))
        }
        return out
    }
}

// MARK: - Responses

/// Decoded `07` device-status frame.
struct BottleStatus: Equatable {
    var isCharging: Bool
    var reminderEnabled: Bool
    var temperatureC: Int
    var batteryPercent: Int
    var screenSeconds: Int
    var isSterilising: Bool
    var steriliseProgress: Int
    var autoSteriliseEnabled: Bool
    var touchLocked: Bool
    var steriliseCount: Int
    var dailyAutoReset: Bool
    var uvIntensity: UVIntensity
    var aiCleanSecondsRemaining: UInt32
    var aiCleanEnabled: Bool
    var aiCleanPermanent: Bool
    /// The exact bytes this was decoded from, for diagnosing unexpected device states.
    var rawHex: String

    var temperatureF: Int { Int((Double(temperatureC) * 9.0 / 5.0 + 32.0).rounded()) }

    init?(frame d: Data) {
        // 18 bytes: opcode + 17 payload bytes.
        guard d.count >= 18, d[d.startIndex] == 0x07 else { return nil }
        let b = { (i: Int) -> UInt8 in d[d.startIndex + i] }

        let flags = b(1)
        isCharging = flags & 0x01 != 0
        reminderEnabled = (flags >> 1) & 0x01 != 0
        temperatureC = Int(b(2))
        batteryPercent = Int(b(3))
        screenSeconds = Int(b(4))
        isSterilising = b(5) == 1
        steriliseProgress = Int(b(6))
        autoSteriliseEnabled = b(7) == 1
        touchLocked = b(8) == 1
        steriliseCount = Int(b(9))
        dailyAutoReset = b(10) == 1
        uvIntensity = b(11) == 0 ? .normal : .strong
        aiCleanSecondsRemaining = (UInt32(b(12)) << 24) | (UInt32(b(13)) << 16)
                                | (UInt32(b(14)) << 8)  |  UInt32(b(15))
        aiCleanEnabled = b(16) == 1
        aiCleanPermanent = b(17) == 1
        rawHex = d.hexString
    }
}

/// Decoded `0B` version frame.
struct BottleVersion: Equatable {
    var firmware: String
    var hardware: String

    init?(frame d: Data) {
        guard d.count >= 5, d[d.startIndex] == 0x0B else { return nil }
        let b = { (i: Int) -> UInt8 in d[d.startIndex + i] }
        firmware = "\(b(2)).\(b(3)).\(b(4))"
        hardware = d.count >= 8 ? "\(b(5)).\(b(6)).\(b(7))" : "1.0.1"
    }
}

/// The `10` frame carries the MAC somewhere inside it, located by OUI prefix.
func parseMacAddress(frame d: Data) -> String? {
    let bytes = [UInt8](d)
    for prefix in BottleProtocol.macPrefixes {
        for start in 0...(max(0, bytes.count - 6)) where start + 6 <= bytes.count {
            if bytes[start] == prefix[0], bytes[start + 1] == prefix[1] {
                return bytes[start..<(start + 6)]
                    .map { String(format: "%02X", $0) }
                    .joined(separator: ":")
            }
        }
    }
    return nil
}

// MARK: - Hex helpers

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }

    init?(hexString: String) {
        let s = hexString.filter { !$0.isWhitespace && $0 != ":" }
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let byte = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        self = out
    }
}
