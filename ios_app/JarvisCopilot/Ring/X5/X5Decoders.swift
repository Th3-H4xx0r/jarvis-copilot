import Foundation

// Decoders for X5 replies. Every function takes the payload as `X5Frames` hands it on: the
// bytes after the opcode (a 16-byte frame's checksum already dropped). Offsets below are into
// that payload, so the sheet's "byte n" is `p[n - 1]`.

struct X5DayTotal: Equatable {
    /// 0 = today; the ring keeps 15 days.
    var daysAgo: Int
    var day: DateComponents
    var steps: Int
    var exerciseSeconds: Int
    var distanceMeters: Int
    /// Hundredths of a kcal, as the ring counts.
    var calories100: Int
}

/// Ten minutes of steps, minute by minute.
struct X5StepBlock: Equatable {
    var id: Int
    var start: Date
    var steps: Int
    var calories100: Int
    var distanceMeters: Int
    var perMinute: [Int]
}

/// Up to two hours of sleep, one stage code per minute (1 deep, 2 light, 3 REM, else awake).
struct X5SleepChunk: Equatable {
    var id: Int
    var start: Date
    var codes: [Int]
}

/// 75 seconds of heart rate, one reading every 5 s (0 = none).
struct X5HRBlock: Equatable {
    var id: Int
    var start: Date
    var bpm: [Int]
}

struct X5Reading: Equatable {
    var id: Int
    var date: Date
    var value: Double
}

struct X5HRV: Equatable {
    var id: Int
    var date: Date
    var hrv: Int
    var heartRate: Int
    var stress: Int
    /// The ring's blood-pressure estimate, taken with the HRV reading.
    var systolic: Int
    var diastolic: Int
    var vascularAging: Int
}

struct X5WorkoutRecord: Equatable {
    var id: Int
    var start: Date
    var sport: Int
    var heartRate: Int
    var seconds: Int
    var steps: Int
    var paceMinutes: Int
    var paceSeconds: Int
    var kcal: Double
    var km: Double
}

/// One `09` live packet.
struct X5Live: Equatable {
    var steps: Int
    var kcal: Double
    var km: Double
    var exerciseMinutes: Int
    var heartRate: Int
    var celsius: Double
    var spo2: Int
}

/// One `18` packet during a workout started from the app.
struct X5WorkoutTick: Equatable {
    var ended = false
    /// The ring ended it itself (no steps for 30 minutes).
    var autoEnded = false
    /// 1 or 2: no steps for 10 / 20 minutes — the app asks whether to end.
    var inactivityPrompt: Int?
    var heartRate = 0
    var steps = 0
    var kcal = 0.0
    var seconds = 0
    var km = 0.0
}

/// A touch gesture, reported as `0A <key>` while the touch surface is in key mode.
enum X5Gesture: UInt8, CaseIterable, Codable {
    case swipeUp = 1, swipeDown = 2, swipeLeft = 3, swipeRight = 4, click = 5
    case doubleClick = 0x0B, longPress = 0x0C, hold5s = 0x0E, hold10s = 0x0F

    /// The shared input this gesture is bound through — the R12's inputs screen and store.
    var input: RingInput {
        switch self {
        case .swipeUp: return .swipeUp
        case .swipeDown: return .swipeDown
        case .swipeLeft: return .swipeLeft
        case .swipeRight: return .swipeRight
        case .click: return .tap
        case .doubleClick: return .doubleTap
        case .longPress: return .longPress
        case .hold5s: return .holdFiveSeconds
        case .hold10s: return .holdTenSeconds
        }
    }
}

struct X5HIDState: Equatable, Codable {
    var enabled: Bool
    var mode: X5HIDMode
    var awakeSeconds: Int
}

struct X5Firmware: Equatable, Codable {
    var version: String
    var built: DateComponents?
}

struct X5Profile: Equatable, Codable {
    var male: Bool
    var age: Int
    var heightCm: Int
    var weightKg: Int
    var strideCm: Int
    var mac: String?
}

enum X5Decode {
    // MARK: Helpers

    private static func u16(_ p: [UInt8], _ i: Int) -> Int {
        guard i + 1 < p.count else { return 0 }
        return Int(p[i]) | Int(p[i + 1]) << 8
    }

    private static func u32(_ p: [UInt8], _ i: Int) -> Int {
        guard i + 3 < p.count else { return 0 }
        return Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16 | Int(p[i + 3]) << 24
    }

    private static func f32(_ p: [UInt8], _ i: Int) -> Double {
        guard i + 3 < p.count else { return 0 }
        let value = Double(Float(bitPattern: UInt32(truncatingIfNeeded: u32(p, i))))
        return value.isFinite ? value : 0
    }

    static func isBCD(_ byte: UInt8) -> Bool { byte >> 4 <= 9 && byte & 0x0F <= 9 }

    /// Six BCD bytes YY MM DD HH mm SS starting at `i`, in `calendar`'s zone.
    static func date(_ p: [UInt8], at i: Int, calendar: Calendar = .current) -> Date? {
        guard i + 5 < p.count, p[i..<(i + 6)].allSatisfy(isBCD) else { return nil }
        let v = p[i..<(i + 6)].map(RingProtocol.fromBCD)
        guard (1...12).contains(v[1]), (1...31).contains(v[2]), v[3] < 24, v[4] < 60, v[5] < 60 else { return nil }
        return calendar.date(from: DateComponents(year: 2000 + v[0], month: v[1], day: v[2],
                                                  hour: v[3], minute: v[4], second: v[5]))
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Settings and status

    static func time(_ p: [UInt8], calendar: Calendar = .current) -> Date? { date(p, at: 0, calendar: calendar) }

    static func profile(_ p: [UInt8]) -> X5Profile? {
        guard p.count >= 5 else { return nil }
        let mac = p.count >= 11 ? hex(p[5..<11]) : nil
        return X5Profile(male: p[0] == 1, age: Int(p[1]), heightCm: Int(p[2]), weightKg: Int(p[3]),
                         strideCm: Int(p[4]), mac: mac)
    }

    /// Percent, charging, and the cell voltage in millivolts.
    static func battery(_ p: [UInt8]) -> (battery: RingBattery, millivolts: Int)? {
        guard p.count >= 4, p[0] <= 100 else { return nil }
        return (RingBattery(percent: Int(p[0]), charging: p[1] == 1), Int(p[2]) << 8 | Int(p[3]))
    }

    static func mac(_ p: [UInt8]) -> String? { p.count >= 6 ? hex(p[0..<6]) : nil }

    /// Four BCD version digits, then the build date.
    static func firmware(_ p: [UInt8]) -> X5Firmware? {
        guard p.count >= 4 else { return nil }
        let version = p[0..<4].map { String(RingProtocol.fromBCD($0)) }.joined(separator: ".")
        var built: DateComponents?
        if p.count >= 7, p[4..<7].allSatisfy(isBCD), p[5] != 0 {
            built = DateComponents(year: 2000 + RingProtocol.fromBCD(p[4]), month: RingProtocol.fromBCD(p[5]),
                                   day: RingProtocol.fromBCD(p[6]))
        }
        return X5Firmware(version: version, built: built)
    }

    static func monitoring(_ p: [UInt8]) -> X5Monitoring? {
        guard p.count >= 9, let type = X5MonitorType(rawValue: p[8]) else { return nil }
        return X5Monitoring(on: p[0] != 0, startHour: RingProtocol.fromBCD(p[1]), startMinute: RingProtocol.fromBCD(p[2]),
                            endHour: RingProtocol.fromBCD(p[3]), endMinute: RingProtocol.fromBCD(p[4]),
                            weekdays: p[5], intervalMinutes: u16(p, 6), type: type)
    }

    /// The touch state read back (`1C 00` reply: op, enabled, mode, delay LE, platform).
    static func hid(_ p: [UInt8]) -> X5HIDState? {
        guard p.count >= 5, let mode = X5HIDMode(rawValue: p[2]) else { return nil }
        return X5HIDState(enabled: p[1] == 1, mode: mode, awakeSeconds: u16(p, 3))
    }

    /// `1C 03` reply: the delay right after the op byte, as the vendor SDK reads it.
    static func hidDelay(_ p: [UInt8]) -> Int? { p.count >= 3 && p[0] == 0x03 ? u16(p, 1) : nil }

    /// `1C 08`: the touch surface timed out and powered down.
    static func isTouchTimeout(_ p: [UInt8]) -> Bool { p.first == 0x08 }

    static func goal(_ p: [UInt8]) -> Int? { p.count >= 4 ? u32(p, 0) : nil }

    /// °C, or nil off the finger (the sensor reads the room).
    static func skinTemp(_ p: [UInt8]) -> Double? {
        guard p.count >= 2 else { return nil }
        let celsius = Double(u16(p, 0)) / 10
        return (25...45).contains(celsius) ? celsius : nil
    }

    /// `28 80` reply: 1 heart rate, 2 HRV, 4 SpO₂, 0 nothing running.
    static func measureStatus(_ p: [UInt8]) -> Int? { p.count >= 2 && p[0] == 0x80 ? Int(p[1]) : nil }

    /// `19` replies. A start answers `ok, YY MM DD HH mm SS`; status and end answer
    /// `state, sport, YY MM DD HH mm SS`.
    static func workoutReply(_ p: [UInt8], calendar: Calendar = .current) -> (ok: Bool, sport: Int?, start: Date?) {
        guard let first = p.first else { return (false, nil, nil) }
        if let start = date(p, at: 1, calendar: calendar) { return (first == 1, nil, start) }
        if p.count >= 8, let start = date(p, at: 2, calendar: calendar) { return (first == 1, Int(p[1]), start) }
        return (first == 1, nil, nil)
    }

    // MARK: Live

    static func live(_ p: [UInt8]) -> X5Live? {
        guard p.count >= 24 else { return nil }
        return X5Live(steps: u32(p, 0), kcal: Double(u32(p, 4)) / 100, km: Double(u32(p, 8)) / 100,
                      exerciseMinutes: Int(p[12]), heartRate: Int(p[20]), celsius: Double(u16(p, 21)) / 10,
                      spo2: Int(p[23]))
    }

    static func gesture(_ p: [UInt8]) -> X5Gesture? { p.first.flatMap(X5Gesture.init(rawValue:)) }

    /// A workout packet. The prompts and the end come as ordinary 16-byte frames (14-byte
    /// payload), so `AA` only means "prompt" there — in a tick it is a heart rate of 170.
    static func tick(_ p: [UInt8]) -> X5WorkoutTick? {
        guard let first = p.first else { return nil }
        let isFrame = p.count == RingProtocol.payloadLength
        if first == 0xFF {
            return X5WorkoutTick(ended: true, autoEnded: p.count > 1 && p[1] == 2)
        }
        if isFrame, first == 0xAA {
            return X5WorkoutTick(inactivityPrompt: p.count > 1 ? Int(p[1]) : nil)
        }
        guard p.count >= 17 else { return nil }
        return X5WorkoutTick(heartRate: Int(first), steps: u32(p, 1), kcal: f32(p, 5), seconds: u32(p, 9), km: f32(p, 13))
    }

    // MARK: History entries

    static func dayTotal(_ p: [UInt8]) -> X5DayTotal? {
        guard p.count >= 20, p[1..<4].allSatisfy(isBCD) else { return nil }
        let day = DateComponents(year: 2000 + RingProtocol.fromBCD(p[1]), month: RingProtocol.fromBCD(p[2]),
                                 day: RingProtocol.fromBCD(p[3]))
        guard let month = day.month, (1...12).contains(month), let d = day.day, (1...31).contains(d) else { return nil }
        return X5DayTotal(daysAgo: Int(p[0]), day: day, steps: u32(p, 4), exerciseSeconds: u32(p, 8),
                          distanceMeters: u32(p, 12) * 10, calories100: u32(p, 16))
    }

    static func stepBlock(_ p: [UInt8], calendar: Calendar = .current) -> X5StepBlock? {
        guard p.count >= 24, let start = date(p, at: 2, calendar: calendar) else { return nil }
        return X5StepBlock(id: u16(p, 0), start: start, steps: u16(p, 8), calories100: u16(p, 10),
                           distanceMeters: u16(p, 12) * 10, perMinute: p[14..<24].map(Int.init))
    }

    static func sleep(_ p: [UInt8], calendar: Calendar = .current) -> X5SleepChunk? {
        guard p.count >= 9, let start = date(p, at: 2, calendar: calendar) else { return nil }
        let length = min(Int(p[8]), 120, p.count - 9)
        return X5SleepChunk(id: u16(p, 0), start: start, codes: p[9..<(9 + max(0, length))].map(Int.init))
    }

    static func continuousHR(_ p: [UInt8], calendar: Calendar = .current) -> X5HRBlock? {
        guard p.count >= 23, let start = date(p, at: 2, calendar: calendar) else { return nil }
        return X5HRBlock(id: u16(p, 0), start: start, bpm: p[8..<23].map(Int.init))
    }

    /// Single heart rate (55), automatic SpO₂ (66) and manual SpO₂ (60): one value after the date.
    static func reading(_ p: [UInt8], calendar: Calendar = .current) -> X5Reading? {
        guard p.count >= 9, let when = date(p, at: 2, calendar: calendar) else { return nil }
        return X5Reading(id: u16(p, 0), date: when, value: Double(p[8]))
    }

    /// °C, dropped outside 25–45 (the sensor reads the room when the ring is off).
    static func temperature(_ p: [UInt8], calendar: Calendar = .current) -> X5Reading? {
        guard p.count >= 10, let when = date(p, at: 2, calendar: calendar) else { return nil }
        let celsius = Double(u16(p, 8)) / 10
        guard (25...45).contains(celsius) else { return nil }
        return X5Reading(id: u16(p, 0), date: when, value: celsius)
    }

    static func hrv(_ p: [UInt8], calendar: Calendar = .current) -> X5HRV? {
        guard p.count >= 14, let when = date(p, at: 2, calendar: calendar) else { return nil }
        return X5HRV(id: u16(p, 0), date: when, hrv: Int(p[8]), heartRate: Int(p[10]), stress: Int(p[11]),
                     systolic: Int(p[12]), diastolic: Int(p[13]), vascularAging: Int(p[9]))
    }

    static func workout(_ p: [UInt8], calendar: Calendar = .current) -> X5WorkoutRecord? {
        guard p.count >= 24, let start = date(p, at: 2, calendar: calendar) else { return nil }
        return X5WorkoutRecord(id: u16(p, 0), start: start, sport: Int(p[8]), heartRate: Int(p[9]),
                               seconds: u16(p, 10), steps: u16(p, 12), paceMinutes: Int(p[14]),
                               paceSeconds: Int(p[15]), kcal: f32(p, 16), km: f32(p, 20))
    }
}
