import Foundation

// MARK: - Vocabulary

enum RingMetric: String, CaseIterable, Codable {
    case activity, sleep
    case heartRate = "heart_rate"
    case spo2, hrv, stress, temperature
    case bloodPressure = "blood_pressure"
    case bloodSugar = "blood_sugar"

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .sleep: return "Sleep"
        case .heartRate: return "Heart rate"
        case .spo2: return "Blood oxygen"
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .temperature: return "Temperature"
        case .bloodPressure: return "Blood pressure"
        case .bloodSugar: return "Blood sugar"
        }
    }
}

/// The `0x69` measurement types a ring can run on demand.
enum RingMeasurementType: UInt8, CaseIterable, Codable {
    case heartRate = 1, bloodPressure = 2, spo2 = 3, healthCheck = 5, stress = 8, bloodSugar = 9, hrv = 10, temperature = 11

    var name: String {
        switch self {
        case .heartRate: return "heart_rate"
        case .bloodPressure: return "blood_pressure"
        case .spo2: return "spo2"
        case .healthCheck: return "health_check"
        case .stress: return "stress"
        case .bloodSugar: return "blood_sugar"
        case .hrv: return "hrv"
        case .temperature: return "temperature"
        }
    }

    var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .bloodPressure: return "Blood pressure"
        case .spo2: return "SpO₂"
        case .healthCheck: return "Health check"
        case .stress: return "Stress"
        case .bloodSugar: return "Blood sugar"
        case .hrv: return "HRV"
        case .temperature: return "Temperature"
        }
    }

    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match
    }
}

/// What a tap, swipe or double-tap on the ring controls (`0x3B` app type).
enum RingTouchMode: UInt8, CaseIterable, Codable {
    case off = 0, music = 1, video = 2, tasbih = 3, pageTurn = 4, photo = 5, game = 7, heartRate = 8, couple = 10

    var name: String {
        switch self {
        case .off: return "off"
        case .music: return "music"
        case .video: return "video"
        case .tasbih: return "tasbih"
        case .pageTurn: return "page_turn"
        case .photo: return "photo"
        case .game: return "game"
        case .heartRate: return "heart_rate"
        case .couple: return "couple"
        }
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .music: return "Music"
        case .video: return "Short video"
        case .tasbih: return "Tasbih"
        case .pageTurn: return "Page turn"
        case .photo: return "Photo"
        case .game: return "Game"
        case .heartRate: return "Heart rate"
        case .couple: return "Couple"
        }
    }

    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match
    }

    /// The modes a ring can advertise. Tasbih and couple have no capability bit, so they only
    /// ever come back from a ring's settings — they are never offered.
    static let offerable: [RingTouchMode] = [.off, .music, .video, .pageTurn, .photo, .game, .heartRate]
}

// MARK: - Capabilities

/// The ring's two capability replies, kept raw so nothing is lost; flags are read on demand.
///
/// Block A is the reply to set-time (`0x01`), block B the reply to `0x3C`. Offsets are
/// payload bytes (frame byte − 1).
struct RingCapabilities: Codable, Equatable {
    var blockA: [UInt8]?
    var blockB: [UInt8]?

    var isKnown: Bool { blockA != nil || blockB != nil }

    private func byteA(_ i: Int) -> UInt8 { byte(blockA, i) }
    private func byteB(_ i: Int) -> UInt8 { byte(blockB, i) }
    private func byte(_ block: [UInt8]?, _ i: Int) -> UInt8 {
        guard let block, i >= 0, i < block.count else { return 0 }
        return block[i]
    }
    private func a(_ i: Int, _ bit: UInt8) -> Bool { byteA(i) & (1 << bit) != 0 }
    private func b(_ i: Int, _ bit: UInt8) -> Bool { byteB(i) & (1 << bit) != 0 }

    // Block A
    var temperature: Bool { byteA(0) == 1 }
    var menstruation: Bool { byteA(2) == 1 }
    var bloodOxygen: Bool { a(3, 1) }
    var bloodPressure: Bool { a(3, 2) }
    var oneKeyCheck: Bool { a(3, 4) }
    var weather: Bool { a(3, 5) }
    /// Sleep comes over large-data `0x27` instead of the legacy `0x44` slots.
    var newSleepProtocol: Bool { byteA(8) == 1 }
    var appMeasure: Bool { a(10, 5) }
    var manualBloodOxygen: Bool { a(10, 6) }
    var manualHeartRate: Bool { a(11, 0) }
    var bloodSugar: Bool { a(11, 7) }
    var stress: Bool { a(13, 4) }
    var hrv: Bool { a(13, 5) }

    // Block B
    var touch: Bool { b(1, 0) }
    var wearingCalibration: Bool { b(1, 2) }
    var blePair: Bool { b(1, 3) }
    /// QRing treats a screenless device reporting this as a band rather than a ring.
    var noScreen: Bool { b(1, 6) }
    var gesture: Bool { b(1, 7) }
    var ringMusic: Bool { b(2, 0) }
    var ringVideo: Bool { b(2, 1) }
    var ringEbook: Bool { b(2, 2) }
    var ringCamera: Bool { b(2, 3) }
    var ringPhoneCall: Bool { b(2, 4) }
    var ringGame: Bool { b(2, 5) }
    var heart: Bool { b(2, 6) }
    var skinTemperature: Bool { b(3, 0) }
    var sedentary: Bool { b(3, 2) }
    var drink: Bool { b(3, 3) }
    var notification: Bool { b(3, 5) }
    var aiAnalyze: Bool { b(3, 7) }
    var gestureDND: Bool { b(4, 3) }
    var touchSleep: Bool { b(4, 4) }
    /// Non-zero byte 5 switches the ring to its "touch-only" mode set.
    var onlyTouch: Bool { byteB(5) != 0 }
    var noTakePhoto: Bool { b(6, 2) }
    var alarm: Bool { b(6, 6) }
    var doNotDisturb: Bool { b(6, 7) }
    var realTimeSpO2: Bool { b(7, 2) }
    /// Heart-rate history comes over large-data `0x75` instead of the legacy `0x15` array.
    var realTimeHeartRate: Bool { b(7, 3) }
    var realTimeHeartRateRemind: Bool { b(7, 4) }
    var temperatureIntervalModify: Bool { b(7, 7) }
    var temperatureReminder: Bool { b(8, 6) }
    /// Temperature history comes over large-data `0x77`.
    var intervalTemperature: Bool { b(8, 7) }
    var ecg: Bool { b(9, 1) }
    var temperatureBoth: Bool { b(9, 2) }
    var breathTraining: Bool { b(9, 3) }
    var bodyBattery: Bool { b(9, 6) }

    var anyTemperature: Bool { temperature || intervalTemperature || skinTemperature || temperatureBoth }

    /// The touch/gesture modes the ring advertises. Block B carries two parallel sets — the
    /// normal one and a "touch-only" one selected by a non-zero byte 5.
    var touchModes: [RingTouchMode] {
        let bits: (Int, UInt8) -> Bool = { index, bit in
            onlyTouch ? b(5, bit) : b(index, bit)
        }
        var modes: [RingTouchMode] = [.off]
        if bits(2, 0) { modes.append(.music) }
        if bits(2, 1) { modes.append(.video) }
        if bits(2, 2) { modes.append(.pageTurn) }
        if bits(2, 3), !noTakePhoto { modes.append(.photo) }
        if bits(2, 5) { modes.append(.game) }
        if bits(2, 6) { modes.append(.heartRate) }
        // A ring that has touch or gestures but names no modes still has the basics.
        if modes == [.off], touch || gesture { modes += [.music, .video, .pageTurn, .photo] }
        return modes
    }

    var supportedMeasurements: [RingMeasurementType] {
        var out: [RingMeasurementType] = [.heartRate]
        if bloodOxygen || manualBloodOxygen { out.append(.spo2) }
        if hrv { out.append(.hrv) }
        if stress { out.append(.stress) }
        if anyTemperature { out.append(.temperature) }
        if bloodPressure { out.append(.bloodPressure) }
        if bloodSugar { out.append(.bloodSugar) }
        if oneKeyCheck { out.append(.healthCheck) }
        return out
    }

    func supports(_ metric: RingMetric) -> Bool {
        switch metric {
        case .activity, .sleep, .heartRate: return true
        case .spo2: return bloodOxygen || manualBloodOxygen
        case .hrv: return hrv
        case .stress: return stress
        case .temperature: return anyTemperature
        case .bloodPressure: return bloodPressure
        case .bloodSugar: return bloodSugar
        }
    }

    /// Every flag with a display name, for the diagnostics screen and `ring_get_status`.
    var allFlags: [(group: String, name: String, on: Bool)] {
        [
            ("Health", "Temperature", temperature), ("Health", "Blood oxygen", bloodOxygen),
            ("Health", "Manual blood oxygen", manualBloodOxygen), ("Health", "Manual heart rate", manualHeartRate),
            ("Health", "Blood pressure", bloodPressure), ("Health", "Blood sugar", bloodSugar),
            ("Health", "Stress", stress), ("Health", "HRV", hrv), ("Health", "One-key check", oneKeyCheck),
            ("Health", "Menstruation", menstruation), ("Health", "Real-time heart rate", realTimeHeartRate),
            ("Health", "Real-time SpO₂", realTimeSpO2), ("Health", "Heart-rate alerts", realTimeHeartRateRemind),
            ("Health", "Skin temperature", skinTemperature), ("Health", "Interval temperature", intervalTemperature),
            ("Health", "Temperature reminder", temperatureReminder), ("Health", "Both temperatures", temperatureBoth),
            ("Health", "ECG", ecg), ("Health", "Body battery", bodyBattery), ("Health", "Breath training", breathTraining),
            ("Sleep", "New sleep protocol", newSleepProtocol),
            ("Controls", "Touch", touch), ("Controls", "Gestures", gesture), ("Controls", "Touch-only modes", onlyTouch),
            ("Controls", "Music", ringMusic), ("Controls", "Video", ringVideo), ("Controls", "E-book", ringEbook),
            ("Controls", "Camera", ringCamera), ("Controls", "Phone call", ringPhoneCall), ("Controls", "Game", ringGame),
            ("Controls", "Heart measure", heart), ("Controls", "Gesture do-not-disturb", gestureDND),
            ("Controls", "Touch sleep", touchSleep),
            ("Device", "Wearing calibration", wearingCalibration), ("Device", "Needs pairing", blePair),
            ("Device", "No screen", noScreen), ("Device", "Sedentary reminder", sedentary),
            ("Device", "Drink reminder", drink), ("Device", "Notifications", notification),
            ("Device", "Alarms", alarm), ("Device", "Do not disturb", doNotDisturb), ("Device", "AI analysis", aiAnalyze),
            ("Device", "App measure", appMeasure), ("Device", "Weather", weather),
        ]
    }
}

// MARK: - Values

struct RingBattery: Codable, Equatable {
    var percent: Int
    var charging: Bool
}

/// Daily totals. The ring counts energy in small calories — QRing divides by 1000 to show kcal.
struct RingActivity: Codable, Equatable {
    var steps: Int
    var runningSteps: Int
    var calories: Int
    var distanceMeters: Int
    var sportMinutes: Int

    var kilocalories: Double { Double(calories) / 1000 }
}

struct RingStepSlot: Codable, Equatable {
    /// 15-minute index, 0…95.
    var slot: Int
    var steps: Int
    var calories: Int
    var distanceMeters: Int
}

struct RingDatedStepSlot: Equatable {
    var dayKey: String
    var slot: RingStepSlot
}

/// Evenly spaced samples from local midnight; 0 means no reading in that slot.
struct RingSeries: Codable, Equatable {
    var intervalMinutes: Int
    var values: [Double]

    var readings: [(minute: Int, value: Double)] {
        values.enumerated().compactMap { index, value in
            value > 0 ? (index * max(1, intervalMinutes), value) : nil
        }
    }
}

struct RingSleepStage: Codable, Equatable {
    static let light = 2, deep = 3, rem = 4, awake = 5

    var stage: Int
    var minutes: Int
}

struct RingSleepSession: Codable, Equatable {
    var start: Date
    var end: Date
    /// Minute-of-day the ring put in the block header; the start above is derived from the
    /// stage durations, as QRing does.
    var reportedStartMinute: Int
    var stages: [RingSleepStage]

    func minutes(of stage: Int) -> Int {
        stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }
    }

    /// Time asleep: everything except the awake stage.
    var asleepMinutes: Int {
        stages.filter { $0.stage != RingSleepStage.awake }.reduce(0) { $0 + $1.minutes }
    }
}

struct RingNap: Codable, Equatable {
    var start: Date
    var end: Date
}

/// Hourly (24-slot) lowest and highest readings.
struct RingMinMax: Codable, Equatable {
    var min: [Int]
    var max: [Int]
}

struct RingTimedValue: Codable, Equatable {
    /// Minute of the local day.
    var minute: Int
    var value: Double
}

struct RingBloodPressureReading: Codable, Equatable {
    var time: Date
    var systolic: Int
    var diastolic: Int
}

struct RingMeasurementReading: Equatable {
    var type: UInt8
    var errorCode: UInt8
    var value: Int
    var systolic: Int
    var diastolic: Int

    /// A temperature reading arrives as `(°C − 20) × 10` in one byte.
    var celsius: Double { Double(value) / 10 + 20 }
}

// MARK: - Settings

struct RingHeartRateMonitor: Codable, Equatable {
    var enabled: Bool
    var intervalMinutes: Int
    var start: Int
    var lowWarning: Int
    var highWarning: Int
    var mainSwitch: Int
    var maxInterval: Int
}

struct RingSpO2Monitor: Codable, Equatable {
    var enabled: Bool
    var intervalMinutes: Int
}

struct RingStressMonitor: Codable, Equatable {
    var enabled: Bool
}

struct RingHRVMonitor: Codable, Equatable {
    var enabled: Bool
    var intervalSupported: Bool
    var intervalMinutes: Int
}

struct RingTemperatureMonitor: Codable, Equatable {
    var enabled: Bool
    var intervalMinutes: Int
    var start: Int
    var remindIntervalMinutes: Int
    /// b0 low, b1 middle, b2 high, b3 custom threshold.
    var alertFlags: Int
    var customAlertCelsius: Double
}

struct RingTouchSettings: Codable, Equatable {
    var isTouch: Bool
    var mode: UInt8
    var sleepTime: Int
    var touchSleep: Bool
    var strength: Int

    var touchMode: RingTouchMode? { RingTouchMode(rawValue: mode) }
}

struct RingDND: Codable, Equatable {
    var enabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var manual: Bool
}

struct RingTemperatureUnit: Codable, Equatable {
    var enabled: Bool
    var celsius: Bool
}

struct RingGoals: Codable, Equatable {
    var steps: Int
    /// Small calories (kcal × 1000), as the ring stores them.
    var calories: Int
    var distanceMeters: Int
    var sportMinutes: Int
    var sleepMinutes: Int
}

struct RingProfile: Codable, Equatable {
    var use24Hour: Bool
    var metric: Bool
    /// 0 male, 1 female (QRing sends its 1/2 value minus one).
    var sex: Int
    var age: Int
    var heightCm: Int
    var weightKg: Int
    var systolic: Int
    var diastolic: Int
    var heartRateWarning: Int
    var open: Int
}

struct RingWearHand: Codable, Equatable {
    var enabled: Bool
    var left: Bool
    var screenLight: Int
    var maxLight: Int
    var dndAllDay: Bool
    var startMinute: Int
    var endMinute: Int
}

struct RingSedentary: Codable, Equatable {
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    /// Bit i = weekday i on; 0 disables the reminder.
    var weekMask: Int
    var cycleMinutes: Int

    var enabled: Bool { weekMask != 0 }
}

// MARK: - Events

/// An unsolicited `0x73` notification.
enum RingDeviceEvent: Equatable {
    case dataUpdated(RingMetric)
    case battery(RingBattery)
    case goalsChanged
    case wearHand(Int)
    case liveActivity(RingActivity)
    case settingsChanged
    case touchSleep(Bool)
    /// 1 swipe down, 2 swipe up, 3 click, 4 long press.
    case touchKey(Int)
    case instantHeartRate(Int)
    case liveTemperature(Double)
    case phoneStillTimeRequest
    case instantSpO2(Int)
    case other(type: Int, payload: [UInt8])
}

// MARK: - Dates

enum RingDates {
    static func midnight(daysAgo: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return dayKey(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Whole days between the key's date and today (0 = today, negative = future).
    static func daysAgo(key: String, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let date = date(forKey: key, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: now)).day
    }
}

// MARK: - Decoders

/// Pure decoders for every reply this app reads. Command offsets are payload offsets
/// (frame byte − 1); large-data offsets are after the 6-byte header.
enum RingDecode {
    private static func at(_ p: [UInt8], _ i: Int) -> Int {
        i >= 0 && i < p.count ? Int(p[i]) : 0
    }

    private static func u16LE(_ p: [UInt8], _ i: Int) -> Int { at(p, i) | at(p, i + 1) << 8 }
    private static func u16BE(_ p: [UInt8], _ i: Int) -> Int { at(p, i) << 8 | at(p, i + 1) }
    private static func u24LE(_ p: [UInt8], _ i: Int) -> Int { at(p, i) | at(p, i + 1) << 8 | at(p, i + 2) << 16 }
    private static func u24BE(_ p: [UInt8], _ i: Int) -> Int { at(p, i) << 16 | at(p, i + 1) << 8 | at(p, i + 2) }
    private static func u32LE(_ p: [UInt8], _ i: Int) -> UInt32 {
        UInt32(at(p, i)) | UInt32(at(p, i + 1)) << 8 | UInt32(at(p, i + 2)) << 16 | UInt32(at(p, i + 3)) << 24
    }

    static func battery(_ p: [UInt8]) -> RingBattery? {
        guard p.count >= 2 else { return nil }
        return RingBattery(percent: at(p, 0), charging: p[1] == 1)
    }

    /// `0x48` today's totals — every field big-endian.
    static func activity(_ p: [UInt8]) -> RingActivity? {
        guard p.count >= 14 else { return nil }
        return RingActivity(steps: u24BE(p, 0), runningSteps: u24BE(p, 3), calories: u24BE(p, 6),
                            distanceMeters: u24BE(p, 9), sportMinutes: u16BE(p, 12))
    }

    // Step slots (0x43) and legacy sleep (0x44) share framing: FF = none, F0 = header,
    // then records carrying (packet index, packet total).

    static func isSlotReplyLast(_ p: [UInt8], first: Bool) -> Bool {
        if first, p.first == 0xFF { return true }
        if first, p.first == 0xF0 { return false }
        guard p.count >= 6 else { return true }
        return p[5] == 0 || Int(p[4]) >= Int(p[5]) - 1
    }

    static func stepDetail(_ frames: [[UInt8]]) -> [RingDatedStepSlot] {
        guard let first = frames.first, first.first != 0xFF else { return [] }
        var scaleTen = false
        var out: [RingDatedStepSlot] = []
        for (index, p) in frames.enumerated() {
            if index == 0, p.first == 0xF0 {
                scaleTen = at(p, 2) == 1
                continue
            }
            guard p.count >= 12 else { continue }
            let key = RingDates.dayKey(year: RingProtocol.fromBCD(p[0]) + 2000,
                                       month: RingProtocol.fromBCD(p[1]), day: RingProtocol.fromBCD(p[2]))
            let slot = RingStepSlot(slot: at(p, 3), steps: u16LE(p, 8),
                                    calories: u16LE(p, 6) * (scaleTen ? 10 : 1), distanceMeters: u16LE(p, 10))
            out.append(RingDatedStepSlot(dayKey: key, slot: slot))
        }
        return out
    }

    /// Legacy sleep slots: day key → slot → the seven quality bytes.
    static func legacySleep(_ frames: [[UInt8]]) -> [String: [Int: [Int]]] {
        guard let first = frames.first, first.first != 0xFF else { return [:] }
        var out: [String: [Int: [Int]]] = [:]
        for (index, p) in frames.enumerated() {
            if index == 0, p.first == 0xF0 { continue }
            guard p.count >= 13 else { continue }
            let key = RingDates.dayKey(year: RingProtocol.fromBCD(p[0]) + 2000,
                                       month: RingProtocol.fromBCD(p[1]), day: RingProtocol.fromBCD(p[2]))
            out[key, default: [:]][at(p, 3)] = (6...12).map { at(p, $0) }
        }
        return out
    }

    /// Multi-packet day series (`0x15`, `0x37`, `0x39`): packet 0 is a header with the
    /// packet count; the reply ends at packet count − 1, or at `FF`.
    static func isDaySeriesLast(_ p: [UInt8], count: inout Int) -> Bool {
        guard let index = p.first else { return true }
        if index == 0xFF { return true }
        if index == 0 {
            count = at(p, 1)
            return count <= 1
        }
        return Int(index) >= count - 1
    }

    /// `0x15` legacy heart-rate array. Packet 1 carries a timestamp before its samples.
    static func heartRateHistory(_ frames: [[UInt8]]) -> RingSeries? {
        daySeries(frames, defaultInterval: 5, firstPacketSkip: 5)
    }

    /// `0x37` stress / `0x39` HRV. Packet 1 carries the day offset before its samples.
    static func hrvOrStress(_ frames: [[UInt8]]) -> RingSeries? {
        daySeries(frames, defaultInterval: 30, firstPacketSkip: 2)
    }

    private static func daySeries(_ frames: [[UInt8]], defaultInterval: Int, firstPacketSkip: Int) -> RingSeries? {
        guard let header = frames.first(where: { $0.first == 0 }) else { return nil }
        let interval = at(header, 2) > 0 ? at(header, 2) : defaultInterval
        var values: [Double] = []
        for p in frames.sorted(by: { at($0, 0) < at($1, 0) }) {
            guard let index = p.first, index != 0, index != 0xFF else { continue }
            let skip = index == 1 ? firstPacketSkip : 1
            guard p.count > skip else { continue }
            values += p[skip...].map { Double($0) }
        }
        let cap = 1440 / max(1, interval)
        if values.count > cap { values = Array(values.prefix(cap)) }
        return RingSeries(intervalMinutes: interval, values: values)
    }

    /// Large-data interval series packet (`0x75` HR, `0x5F` SpO₂, `0x77` temperature).
    /// Temperature samples are u16 LE hundredths of a degree.
    static func intervalPacket(_ p: [UInt8], wide: Bool)
        -> (dayOffset: Int, intervalMinutes: Int, count: Int, index: Int, values: [Double])? {
        guard p.count >= 4 else { return nil }
        var values: [Double] = []
        if wide {
            var i = 4
            while i + 1 < p.count {
                values.append(Double(u16LE(p, i)) / 100)
                i += 2
            }
        } else {
            values = p.dropFirst(4).map { Double($0) }
        }
        return (at(p, 0), at(p, 1), at(p, 2), at(p, 3), values)
    }

    /// Large-data `0x27`. Blocks: dayOffset, length, start minute, end minute, then
    /// (stage, minutes) pairs. End is minutes after that day's local midnight; start is end
    /// minus the stage durations (the header start can belong to the previous day).
    static func sleep(_ p: [UInt8], now: Date = Date(), calendar: Calendar = .current)
        -> [(dayOffset: Int, session: RingSleepSession)] {
        guard at(p, 0) > 0 else { return [] }
        var out: [(dayOffset: Int, session: RingSleepSession)] = []
        var i = 1
        while i + 6 <= p.count {
            let dayOffset = at(p, i)
            let blockEnd = min(p.count, i + 2 + at(p, i + 1))
            guard blockEnd - i >= 6 else { break }
            let startMinute = u16LE(p, i + 2)
            let endMinute = u16LE(p, i + 4)
            var stages: [RingSleepStage] = []
            var j = i + 6
            while j + 1 < blockEnd {
                stages.append(RingSleepStage(stage: at(p, j), minutes: at(p, j + 1)))
                j += 2
            }
            let midnight = RingDates.midnight(daysAgo: dayOffset, now: now, calendar: calendar)
            let end = midnight.addingTimeInterval(TimeInterval(endMinute * 60))
            let total = stages.reduce(0) { $0 + $1.minutes }
            let start = end.addingTimeInterval(TimeInterval(-total * 60))
            out.append((dayOffset, RingSleepSession(start: start, end: end,
                                                    reportedStartMinute: startMinute, stages: stages)))
            i = blockEnd
        }
        return out
    }

    /// Large-data `0x3E` naps: same block layout, pairs are (asleep flag, minutes); runs of
    /// non-zero flags are naps.
    static func naps(_ p: [UInt8], now: Date = Date(), calendar: Calendar = .current)
        -> [(dayOffset: Int, naps: [RingNap])] {
        guard at(p, 0) > 0 else { return [] }
        var out: [(dayOffset: Int, naps: [RingNap])] = []
        var i = 1
        while i + 6 <= p.count {
            let dayOffset = at(p, i)
            let blockEnd = min(p.count, i + 2 + at(p, i + 1))
            guard blockEnd - i >= 6 else { break }
            let midnight = RingDates.midnight(daysAgo: dayOffset, now: now, calendar: calendar)
            let time = { (minute: Int) in midnight.addingTimeInterval(TimeInterval(minute * 60)) }
            var cursor = u16LE(p, i + 2)
            var openedAt: Int?
            var naps: [RingNap] = []
            var j = i + 6
            while j + 1 < blockEnd {
                let asleep = p[j] != 0
                let minutes = at(p, j + 1)
                if asleep {
                    if openedAt == nil { openedAt = cursor }
                } else if let opened = openedAt {
                    naps.append(RingNap(start: time(opened), end: time(cursor)))
                    openedAt = nil
                }
                cursor += minutes
                j += 2
            }
            if let opened = openedAt { naps.append(RingNap(start: time(opened), end: time(cursor))) }
            out.append((dayOffset, naps))
            i = blockEnd
        }
        return out
    }

    /// Large-data `0x28` / `0x49`: day index, then (minute u16 LE, value) triples.
    static func manualList(_ p: [UInt8]) -> (dayOffset: Int, values: [RingTimedValue])? {
        guard !p.isEmpty else { return nil }
        var values: [RingTimedValue] = []
        var i = 1
        while i + 2 < p.count {
            let minute = u16LE(p, i)
            let value = at(p, i + 2)
            if value > 0, minute < 1440 { values.append(RingTimedValue(minute: minute, value: Double(value))) }
            i += 3
        }
        return (at(p, 0), values)
    }

    /// Large-data `0x2A` SpO₂ / `0x47` blood sugar: 49-byte records — days ago, then 24
    /// hourly (max, min) pairs.
    static func hourlyMinMax(_ p: [UInt8]) -> [(dayOffset: Int, value: RingMinMax)] {
        stride(from: 0, to: p.count - 48, by: 49).map { start in
            let record = Array(p[start..<(start + 49)])
            let max = stride(from: 1, to: 49, by: 2).map { Int(record[$0]) }
            let min = stride(from: 2, to: 49, by: 2).map { Int(record[$0]) }
            return (Int(Int8(bitPattern: record[0])), RingMinMax(min: min, max: max))
        }
    }

    static func isBloodPressureEnd(_ p: [UInt8]) -> Bool {
        p.count < 6 || p.prefix(4).allSatisfy { $0 == 0xFF }
    }

    /// `0x14` blood-pressure record: local-time u32 LE, diastolic, systolic.
    static func bloodPressureRecord(_ p: [UInt8], timeZone: TimeZone = .current) -> RingBloodPressureReading? {
        guard !isBloodPressureEnd(p) else { return nil }
        let local = TimeInterval(u32LE(p, 0))
        let offset = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: local)))
        return RingBloodPressureReading(time: Date(timeIntervalSince1970: local - offset),
                                        systolic: at(p, 5), diastolic: at(p, 4))
    }

    static func measurement(_ p: [UInt8]) -> RingMeasurementReading? {
        guard p.count >= 3 else { return nil }
        return RingMeasurementReading(type: p[0], errorCode: p[1], value: at(p, 2),
                                      systolic: at(p, 3), diastolic: at(p, 4))
    }

    // Settings replies only carry values when the action byte is a read (1, or 3 for ring reads).

    static func heartRateMonitor(_ p: [UInt8]) -> RingHeartRateMonitor? {
        guard p.count >= 3, p[0] == 1 else { return nil }
        return RingHeartRateMonitor(enabled: p[1] == 1, intervalMinutes: at(p, 2),
                                    start: at(p, 3) == 0 ? 5 : at(p, 3), lowWarning: at(p, 4),
                                    highWarning: at(p, 5), mainSwitch: at(p, 6),
                                    maxInterval: at(p, 7) == 0 ? 60 : at(p, 7))
    }

    static func spo2Monitor(_ p: [UInt8]) -> RingSpO2Monitor? {
        guard p.count >= 2, p[0] == 1 else { return nil }
        return RingSpO2Monitor(enabled: p[1] == 1, intervalMinutes: at(p, 2))
    }

    static func stressMonitor(_ p: [UInt8]) -> RingStressMonitor? {
        guard p.count >= 2, p[0] == 1 else { return nil }
        return RingStressMonitor(enabled: p[1] == 1)
    }

    static func hrvMonitor(_ p: [UInt8]) -> RingHRVMonitor? {
        guard p.count >= 2, p[0] == 1 else { return nil }
        let code = at(p, 3)
        return RingHRVMonitor(enabled: p[1] == 1, intervalSupported: at(p, 2) == 10,
                              intervalMinutes: code == 0 || code == 0x60 ? 60 : code)
    }

    static func temperatureMonitor(_ p: [UInt8]) -> RingTemperatureMonitor? {
        guard p.count >= 8, p[0] == 3, p[1] == 1 else { return nil }
        return RingTemperatureMonitor(enabled: p[2] == 1, intervalMinutes: at(p, 3), start: at(p, 4),
                                      remindIntervalMinutes: at(p, 5), alertFlags: at(p, 6),
                                      customAlertCelsius: (Double(at(p, 7)) + 200) / 10)
    }

    static func touch(_ p: [UInt8]) -> RingTouchSettings? {
        guard p.count >= 4, p[0] == 1 else { return nil }
        let isTouch = p[1] == 0
        return RingTouchSettings(isTouch: isTouch, mode: p[2],
                                 sleepTime: isTouch ? at(p, 3) : 0,
                                 touchSleep: isTouch && at(p, 4) == 1,
                                 strength: isTouch ? 0 : at(p, 3))
    }

    static func dnd(_ p: [UInt8]) -> RingDND? {
        guard p.count >= 6, p[0] == 1 else { return nil }
        return RingDND(enabled: p[1] == 1, startHour: at(p, 2), startMinute: at(p, 3),
                       endHour: at(p, 4), endMinute: at(p, 5), manual: at(p, 6) == 1)
    }

    static func temperatureUnit(_ p: [UInt8]) -> RingTemperatureUnit? {
        guard p.count >= 3, p[0] == 1 else { return nil }
        return RingTemperatureUnit(enabled: p[1] == 1, celsius: p[2] == 1)
    }

    static func goals(_ p: [UInt8]) -> RingGoals? {
        guard p.count >= 14, p[0] == 1 else { return nil }
        return RingGoals(steps: u24LE(p, 1), calories: u24LE(p, 4), distanceMeters: u24LE(p, 7),
                         sportMinutes: u16LE(p, 10), sleepMinutes: u16LE(p, 12))
    }

    static func profile(_ p: [UInt8]) -> RingProfile? {
        guard p.count >= 11, p[0] == 1 else { return nil }
        return RingProfile(use24Hour: p[1] == 0, metric: p[2] == 0, sex: at(p, 3), age: at(p, 4),
                           heightCm: at(p, 5), weightKg: at(p, 6), systolic: at(p, 7), diastolic: at(p, 8),
                           heartRateWarning: at(p, 9), open: at(p, 10))
    }

    static func wearHand(_ p: [UInt8]) -> RingWearHand? {
        guard p.count >= 10, p[0] == 3 else { return nil }
        return RingWearHand(enabled: p[1] == 1, left: p[2] == 1, screenLight: at(p, 3), maxLight: at(p, 4),
                            dndAllDay: at(p, 5) != 1, startMinute: at(p, 6) * 60 + at(p, 7),
                            endMinute: at(p, 8) * 60 + at(p, 9))
    }

    static func sedentary(_ p: [UInt8]) -> RingSedentary? {
        guard p.count >= 6 else { return nil }
        return RingSedentary(startHour: RingProtocol.fromBCD(p[0]), startMinute: RingProtocol.fromBCD(p[1]),
                             endHour: RingProtocol.fromBCD(p[2]), endMinute: RingProtocol.fromBCD(p[3]),
                             weekMask: at(p, 4), cycleMinutes: at(p, 5))
    }

    static func calibration(_ p: [UInt8]) -> (dataType: Int, result: Int) {
        (at(p, 0), at(p, 9))
    }

    static func deviceEvent(_ p: [UInt8]) -> RingDeviceEvent {
        guard let type = p.first else { return .other(type: -1, payload: p) }
        switch type {
        case 1: return .dataUpdated(.heartRate)
        case 2: return .dataUpdated(.bloodPressure)
        case 3: return .dataUpdated(.spo2)
        case 4: return .dataUpdated(.activity)
        case 5, 39: return .dataUpdated(.temperature)
        case 13: return .dataUpdated(.bloodSugar)
        case 43: return .dataUpdated(.hrv)
        case 44: return .dataUpdated(.stress)
        case 12: return .battery(RingBattery(percent: at(p, 1), charging: at(p, 2) > 0))
        case 16: return .goalsChanged
        case 17: return .wearHand(at(p, 2))
        case 18:
            guard p.count >= 10 else { return .other(type: 18, payload: p) }
            return .liveActivity(RingActivity(steps: u24BE(p, 1), runningSteps: 0, calories: u24BE(p, 4),
                                              distanceMeters: u24BE(p, 7), sportMinutes: 0))
        case 40: return .settingsChanged
        case 42: return .touchSleep(at(p, 1) == 1)
        case 45: return .touchKey(at(p, 1))
        case 55: return .instantHeartRate(at(p, 1))
        case 61: return .liveTemperature(Double(u16LE(p, 1)) / 10)
        case 62: return .phoneStillTimeRequest
        case 64: return .instantSpO2(at(p, 1))
        default: return .other(type: Int(type), payload: p)
        }
    }
}
