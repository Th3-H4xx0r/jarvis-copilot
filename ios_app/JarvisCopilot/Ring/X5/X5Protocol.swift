import CoreBluetooth
import Foundation

/// Wire format for the X5 touch ring (Shenzhen Youhong / J-Style "Touch ring", model X5).
///
/// One service, two characteristics: the app writes 16-byte frames to FFF6 and the ring
/// notifies on FFF7. A frame is `[cmd][14 payload][sum of bytes 0…14 & 0xFF]` — the same
/// framing as the Colmi ring, so requests are built with `RingProtocol.frame`. Replies echo the
/// opcode, or set bit 7 on failure. History and live data come back as variable-length
/// notifications with no checksum (see `X5Frames`).
///
/// Dates on the wire are BCD (`0x24` = 2024, `0x59` = 59 s): the vendor's worked examples and
/// SDK agree on that, whatever the English column of its sheet says.
enum X5Protocol {
    static let service = CBUUID(string: "FFF0")
    static let write = CBUUID(string: "FFF6")
    static let notify = CBUUID(string: "FFF7")

    /// "X5" as a word anywhere in the name ("X5_7A21", "X5 ring", "Smart Ring X5"), not inside
    /// another one ("X50", "AX5B"). FFF0 is a generic service, so a name match is only a
    /// candidate — the manager still checks the ring answers like an X5 before remembering it.
    static func isX5Name(_ name: String) -> Bool {
        let chars = Array(name.uppercased())
        guard chars.count >= 2 else { return false }
        for i in 0..<(chars.count - 1) where chars[i] == "X" && chars[i + 1] == "5" {
            let before = i == 0 ? nil : chars[i - 1]
            let after = i + 2 < chars.count ? chars[i + 2] : nil
            let isWord = { (c: Character?) in c.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWord(before), !isWord(after) { return true }
        }
        return false
    }

    /// Six BCD bytes: YY MM DD HH mm SS in `calendar`'s zone.
    static func timestamp(_ date: Date, calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return [(c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
            .map(RingProtocol.bcd)
    }
}

/// Opcodes that are not history kinds.
enum X5Op {
    static let setTime: UInt8 = 0x01
    static let getTime: UInt8 = 0x41
    static let setProfile: UInt8 = 0x02
    static let getProfile: UInt8 = 0x42
    static let battery: UInt8 = 0x13
    static let mac: UInt8 = 0x22
    static let firmware: UInt8 = 0x27
    static let power: UInt8 = 0x12
    static let restart: UInt8 = 0x2E
    static let live: UInt8 = 0x09
    static let skinTemp: UInt8 = 0x14
    static let measure: UInt8 = 0x28
    static let setMonitoring: UInt8 = 0x2A
    static let getMonitoring: UInt8 = 0x2B
    static let workout: UInt8 = 0x19
    static let workoutTick: UInt8 = 0x18
    static let hid: UInt8 = 0x1C
    static let key: UInt8 = 0x0A
    static let setGoal: UInt8 = 0x0B
    static let getGoal: UInt8 = 0x4B
    static let ppg: UInt8 = 0x78
    static let clearAll: UInt8 = 0x61
    /// The ring's alert, `36 NN` — NN pulses. Not on the X5's sheet: the vendor library's parser
    /// files a `0x36` reply as `MotorVibration_X5` (its opcode table, index 0x35 + 1), as the
    /// vendor's sibling rings document it.
    static let alert: UInt8 = 0x36
    /// The one opcode with bit 7 set that is not an error reply.
    static let unbind: UInt8 = 0x87
}

/// The ring's history stores. Each answers `<op> 00 …` with entries of a fixed length, several
/// to a notification, and ends with `<op> FF`.
enum X5HistoryKind: UInt8, CaseIterable, Codable {
    case dayTotals = 0x51
    case stepBlocks = 0x52
    case sleep = 0x53
    case continuousHR = 0x54
    case singleHR = 0x55
    case hrv = 0x56
    case temperature = 0x62
    case autoSpO2 = 0x66
    case manualSpO2 = 0x60
    case workouts = 0x5C

    /// Bytes per entry, opcode included — as the vendor SDK parses them (the sheet's prose
    /// gives other figures for two of these; its worked examples agree with the SDK).
    var entryLength: Int {
        switch self {
        case .dayTotals: return 27
        case .stepBlocks: return 25
        case .sleep: return 130
        case .continuousHR: return 24
        case .singleHR: return 10
        case .hrv: return 15
        case .temperature: return 11
        case .autoSpO2: return 10
        case .manualSpO2: return 10
        case .workouts: return 25
        }
    }
}

enum X5MonitorType: UInt8, CaseIterable, Codable {
    case heartRate = 1, spo2 = 2, hrv = 4
}

/// What the touch surface does (`1C` mode byte).
enum X5HIDMode: UInt8, CaseIterable, Codable {
    /// Every gesture is reported to the app as a `0A` key event.
    case keys = 0
    /// The ring acts as a Bluetooth keyboard for short-video apps.
    case shortVideo = 1
    case music = 2
    /// Any gesture is a volume key, which the Camera app takes as the shutter.
    case camera = 3
}

/// The ring's sports, by its own ids.
enum X5Sport: Int, CaseIterable, Codable {
    case run, cycling, badminton, football, tennis, yoga, meditation, dance, basketball, walk,
         workout, cricket, hiking, aerobics, pingPong, ropeJump, sitUps, volleyball

    var label: String {
        switch self {
        case .run: return "Run"
        case .cycling: return "Cycling"
        case .badminton: return "Badminton"
        case .football: return "Football"
        case .tennis: return "Tennis"
        case .yoga: return "Yoga"
        case .meditation: return "Meditation"
        case .dance: return "Dance"
        case .basketball: return "Basketball"
        case .walk: return "Walk"
        case .workout: return "Workout"
        case .cricket: return "Cricket"
        case .hiking: return "Hiking"
        case .aerobics: return "Aerobics"
        case .pingPong: return "Ping-pong"
        case .ropeJump: return "Rope jump"
        case .sitUps: return "Sit-ups"
        case .volleyball: return "Volleyball"
        }
    }
}

/// One automatic-measurement schedule (`2A`/`2B`).
struct X5Monitoring: Equatable, Codable {
    var on: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    /// Bit 0 = Sunday … bit 6 = Saturday.
    var weekdays: UInt8
    var intervalMinutes: Int
    var type: X5MonitorType
}

private func u16LE(_ value: Int) -> [UInt8] {
    let v = max(0, min(0xFFFF, value))
    return [UInt8(v & 0xFF), UInt8(v >> 8)]
}

private func u32LE(_ value: Int) -> [UInt8] {
    let v = UInt32(clamping: max(0, value))
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}

private func byte(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }

extension RingRequest {
    static func x5SetTime(_ date: Date, calendar: Calendar = .current) -> RingRequest {
        .command(X5Op.setTime, X5Protocol.timestamp(date, calendar: calendar))
    }
    static var x5GetTime: RingRequest { .command(X5Op.getTime) }

    static func x5SetProfile(male: Bool, age: Int, heightCm: Int, weightKg: Int, strideCm: Int) -> RingRequest {
        .command(X5Op.setProfile, [male ? 1 : 0, byte(age), byte(heightCm), byte(weightKg), byte(strideCm)])
    }
    static var x5GetProfile: RingRequest { .command(X5Op.getProfile) }
    static var x5Battery: RingRequest { .command(X5Op.battery) }
    static var x5Mac: RingRequest { .command(X5Op.mac) }
    static var x5Firmware: RingRequest { .command(X5Op.firmware) }
    static var x5Restart: RingRequest { .command(X5Op.restart) }

    static func x5Alert(pulses: Int) -> RingRequest { .command(X5Op.alert, [UInt8(max(1, min(10, pulses)))]) }
    static var x5SkinTemp: RingRequest { .command(X5Op.skinTemp) }

    /// `09 01 01` starts the live stream with a packet every second — what the sheet's spot
    /// measurement asks for; the SDK's `09 01 00` only reports when the step count changes, so a
    /// still finger gets nothing. `09 00` stops it.
    static func x5Live(_ on: Bool) -> RingRequest { .command(X5Op.live, on ? [1, 1] : [0]) }

    /// `kind`: 1 = 50 Hz raw, 2 = heart rate, 3 = SpO₂. Under 30 s the ring uses 30 s.
    static func x5Measure(_ kind: UInt8, start: Bool, seconds: Int) -> RingRequest {
        .command(X5Op.measure, [kind, start ? 1 : 0, 0] + u16LE(seconds))
    }
    /// `28 80`: which measurement is running (1 HR, 2 HRV, 4 SpO₂, 0 none).
    static var x5MeasureStatus: RingRequest { .command(X5Op.measure, [0x80]) }

    static func x5SetMonitoring(_ m: X5Monitoring) -> RingRequest {
        .command(X5Op.setMonitoring,
                 [m.on ? 2 : 0, RingProtocol.bcd(m.startHour), RingProtocol.bcd(m.startMinute),
                  RingProtocol.bcd(m.endHour), RingProtocol.bcd(m.endMinute), m.weekdays]
                     + u16LE(m.intervalMinutes) + [m.type.rawValue])
    }
    static func x5GetMonitoring(_ type: X5MonitorType) -> RingRequest {
        .command(X5Op.getMonitoring, [type.rawValue])
    }

    /// `00` reads the newest 50 entries; with `after` set, only entries newer than that
    /// timestamp — which has to be one the ring actually holds.
    static func x5History(_ kind: X5HistoryKind, after: Date?, calendar: Calendar = .current) -> RingRequest {
        var payload: [UInt8] = [0x00, 0x00, 0x00]
        if let after { payload += X5Protocol.timestamp(after, calendar: calendar) }
        return .command(kind.rawValue, payload)
    }
    /// The next 50 entries after the last page.
    static func x5HistoryNext(_ kind: X5HistoryKind) -> RingRequest { .command(kind.rawValue, [0x02]) }
    /// Deletes that store on the ring. Only ever sent from an explicit, confirmed user action.
    static func x5HistoryDelete(_ kind: X5HistoryKind) -> RingRequest { .command(kind.rawValue, [0x99]) }

    /// `action`: 1 start, 2 pause, 3 resume, 4 end, 5 status. Meditation takes a level and minutes.
    static func x5Workout(_ action: UInt8, sport: X5Sport, level: Int = 0, minutes: Int = 0) -> RingRequest {
        .command(X5Op.workout, [action, UInt8(sport.rawValue), byte(level), byte(minutes)])
    }

    /// `1C 01`: touch on/off, its mode, how long it stays awake (0 keeps the previous delay)
    /// and the phone platform (1 = iOS).
    static func x5SetHID(enabled: Bool, mode: X5HIDMode, awakeSeconds: Int) -> RingRequest {
        .command(X5Op.hid, [0x01, enabled ? 1 : 0, mode.rawValue] + u16LE(awakeSeconds) + [0x01])
    }
    static var x5GetHID: RingRequest { .command(X5Op.hid, [0x00]) }
    static func x5SetHIDDelay(_ seconds: Int) -> RingRequest { .command(X5Op.hid, [0x02] + u16LE(seconds)) }
    static var x5GetHIDDelay: RingRequest { .command(X5Op.hid, [0x03]) }

    static func x5SetGoal(_ steps: Int) -> RingRequest { .command(X5Op.setGoal, u32LE(steps)) }
    static var x5GetGoal: RingRequest { .command(X5Op.getGoal) }

    /// PPG waveform: 1 start, 2 send result (status 0–3), 3 stop, 4 send progress (0–100), 5 quit.
    static func x5PPG(_ mode: UInt8, status: Int = 0) -> RingRequest {
        mode == 2 || mode == 4 ? .command(X5Op.ppg, [mode, byte(status)]) : .command(X5Op.ppg, [mode])
    }

    /// `12 01` powers the ring off until it is charged; `12 00` drops to factory minimum current.
    static func x5Power(off: Bool) -> RingRequest { .command(X5Op.power, [off ? 1 : 0]) }
    static var x5ClearAll: RingRequest { .command(X5Op.clearAll) }
    static var x5Unbind: RingRequest { .command(X5Op.unbind) }
}
