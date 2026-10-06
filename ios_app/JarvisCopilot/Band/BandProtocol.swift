import CoreBluetooth
import Foundation

/// Wire format for the HBand / Veepoo screenless band (model E910).
///
/// One service, two characteristics: the app writes to F0080003 and the band notifies on
/// F0080002. A frame is 20 bytes, opcode first, no checksum; a request is padded with zeros. The
/// handshake (`A1`, the PIN "0000" is implied by the zero bytes after the opcode) has to succeed
/// before anything else answers, and the band sends its feature tables (`A7`), notification
/// switches (`AD`) and settings (`B8`) ahead of the `A1` reply.
///
/// Everything here mirrors the vendor's WeChat JS SDK, run offline as an oracle: requests are the
/// bytes it writes, decoders give what its parsers give. Two writes are longer than 20 bytes
/// (setting and deleting a text alarm) — the SDK sends those as one long write.
enum BandProtocol {
    static let service = CBUUID(string: "F0080001-0451-4000-B000-000000000000")
    static let write = CBUUID(string: "F0080003-0451-4000-B000-000000000000")
    static let notify = CBUUID(string: "F0080002-0451-4000-B000-000000000000")
    static let frameLength = 20
    /// The only PIN the SDK ever uses; it is not on the wire as such.
    static let pin = "0000"
}

/// Opcodes, as the first byte of a request and of its reply.
enum BandOp {
    static let battery: UInt8 = 0xA0
    static let password: UInt8 = 0xA1
    static let profile: UInt8 = 0xA3
    static let syncTime: UInt8 = 0xA5
    static let readTime: UInt8 = 0xA6
    /// Feature tables, five packages, sent during the handshake.
    static let features: UInt8 = 0xA7
    /// Today's step count only (big-endian); `steps` has distance and energy too.
    static let stepCount: UInt8 = 0xA8
    static let raiseToWake: UInt8 = 0xAA
    static let heartRateAlarm: UInt8 = 0xAC
    /// Phone-notification (ANCS) switches, two packages.
    static let alerts: UInt8 = 0xAD
    static let disconnect: UInt8 = 0xAF
    static let bloodOxygenAuto: UInt8 = 0xB3
    /// The personal blood-pressure reference (the SDK's "private mode").
    static let bloodPressureCalibration: UInt8 = 0x91
    static let screenTime: UInt8 = 0xB4
    static let find: UInt8 = 0xB5
    static let camera: UInt8 = 0xB6
    /// Units, 24-hour clock and the auto-measure switches, two packages.
    static let settings: UInt8 = 0xB8
    /// Text alarms.
    static let alarms: UInt8 = 0xB9
    static let heartRate: UInt8 = 0xD0
    static let sportCRC: UInt8 = 0xD3
    static let sportRecords: UInt8 = 0xD4
    /// The band's own sport mode (started on the band, not from the app).
    static let deviceSport: UInt8 = 0xD5
    static let steps: UInt8 = 0xD8
    /// App sport control: start / pause / resume / stop and the live status read.
    static let sportControl: UInt8 = 0xDA
    static let daily: UInt8 = 0xDF
    static let sleep: UInt8 = 0xE0
    static let sedentary: UInt8 = 0xE1
    static let healthTips: UInt8 = 0xE7
    static let factoryReset: UInt8 = 0xF1
    static let language: UInt8 = 0xF4
    static let product: UInt8 = 0xFC
    static let reboot: UInt8 = 0xFF
    static let bloodOxygen: UInt8 = 0x80
    static let temperature: UInt8 = 0x87
    static let autoTemperature: UInt8 = 0x88
    /// Blood glucose (`89 01`) and stress (`89 06`) share the opcode.
    static let glucoseStress: UInt8 = 0x89
    static let bloodComponent: UInt8 = 0x8A
    static let bloodPressure: UInt8 = 0x90
    /// ECG (`93 01`) and body composition (`93 04`) share the opcode. The ECG waveform itself
    /// comes on `88` (byte 1 ≠ 1), four frames a second; nothing here reads it.
    static let ecgBody: UInt8 = 0x93

    /// What the band sends between the `A1` write and its `A1` reply, the reply included.
    static let handshakeReplies: Set<UInt8> = [features, alerts, settings, password]
    static let measurementReplies: Set<UInt8> = [heartRate, bloodPressure, bloodOxygen, temperature,
                                                 glucoseStress, bloodComponent, ecgBody]
    static let dailyReplies: Set<UInt8> = [daily]
    static let sleepReplies: Set<UInt8> = [sleep]
    static let sportReplies: Set<UInt8> = [sportControl, sportCRC, sportRecords, deviceSport]
}

/// What the band can measure on demand. HRV and MET have no command of their own: HRV comes in
/// the daily records and in the ECG stream, MET only in the daily records.
enum BandMeasure: String, CaseIterable, Codable {
    case heartRate = "heart_rate"
    case bloodPressure = "blood_pressure"
    case bloodOxygen = "spo2"
    case temperature
    case stress
    case bloodGlucose = "blood_glucose"
    case bloodComponent = "blood_component"
    case bodyComposition = "body_composition"
    case ecg

    /// The name skills and JSON use.
    var name: String { rawValue }

    /// The longest a reading runs before it ends as "no reading". Heart rate and SpO₂ stream
    /// until stopped (the SDK docs: stop them after about a minute; a value comes in 10–20 s);
    /// blood pressure takes 50–55 s (iOS SDK doc); the rest count progress to 100 and then send
    /// their result. Generous on purpose: the band's own end frame normally comes first.
    var timeout: TimeInterval {
        switch self {
        case .heartRate: return 45
        case .bloodOxygen: return 60
        case .bloodPressure: return 80
        case .temperature, .stress, .bloodGlucose: return 90
        case .bloodComponent, .bodyComposition, .ecg: return 120
        }
    }

    /// ECG and body composition need a finger on the band's electrode for the whole reading.
    var usesElectrode: Bool { self == .ecg || self == .bodyComposition }

    init?(name: String) {
        let key = name.lowercased()
        if key == "blood_oxygen" || key == "oxygen" { self = .bloodOxygen; return }
        guard let match = Self(rawValue: key) else { return nil }
        self = match
    }

    static var spo2: BandMeasure { .bloodOxygen }
}

/// App sport control op codes (`DA 01 <mode LE> <op>`); sport mode 0 is an app-run sport.
enum BandSportOp: UInt8, CaseIterable, Codable {
    case start = 1, pause = 2, resume = 3, stop = 4
}

enum BandWeekday: String, CaseIterable, Codable {
    case mon, tue, wed, thu, fri, sat, sun

    /// Bit 0 = Monday … bit 6 = Sunday, as the alarm frames carry them.
    var bit: UInt8 { UInt8(1) << UInt8(Self.allCases.firstIndex(of: self) ?? 0) }

    static func days(_ mask: UInt8) -> [BandWeekday] { allCases.filter { mask & $0.bit != 0 } }
    static func mask(_ days: [BandWeekday]) -> UInt8 { days.reduce(0) { $0 | $1.bit } }
}

/// "HH:MM" ↔ hour and minute, for the JSON the skills read and write.
enum BandClock {
    static func string(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    static func parse(_ value: Any?) -> (hour: Int, minute: Int)? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}

// MARK: - Writable settings

/// One text alarm (`B9`). An alarm with no days rings once.
struct BandAlarm: Equatable, Codable {
    var id: Int
    var hour: Int
    var minute: Int
    var days: [BandWeekday]
    var enabled: Bool
    /// The band shows it; up to the band's own limit (UTF-8).
    var label: String = ""

    var json: [String: Any] {
        ["id": id, "time": BandClock.string(hour, minute), "days": days.map(\.rawValue), "enabled": enabled,
         "label": label]
    }

    /// `time` is required; `id` defaults to 1, `days` to none (once), `enabled` to true.
    init?(json: [String: Any]) {
        guard let time = BandClock.parse(json["time"]) else { return nil }
        let id = (json["id"] as? Int) ?? (json["id"] as? Double).map(Int.init) ?? 1
        guard (0...255).contains(id) else { return nil }
        var days: [BandWeekday] = []
        if let raw = json["days"] {
            guard let names = raw as? [String] else { return nil }
            for name in names {
                guard let day = BandWeekday(rawValue: String(name.lowercased().prefix(3))) else { return nil }
                if !days.contains(day) { days.append(day) }
            }
        }
        self.init(id: id, hour: time.hour, minute: time.minute,
                  days: BandWeekday.allCases.filter(days.contains), enabled: (json["enabled"] as? Bool) ?? true,
                  label: (json["label"] as? String) ?? (json["name"] as? String) ?? "")
    }

    init(id: Int, hour: Int, minute: Int, days: [BandWeekday], enabled: Bool, label: String = "") {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.days = days
        self.enabled = enabled
        self.label = label
    }
}

/// The sedentary reminder (`E1`).
struct BandSedentary: Equatable, Codable {
    var enabled: Bool
    var intervalMinutes: Int
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    var json: [String: Any] {
        ["enabled": enabled, "interval_minutes": intervalMinutes, "start": BandClock.string(startHour, startMinute),
         "end": BandClock.string(endHour, endMinute)]
    }

    /// Missing keys fall back to `base` (or 09:00–18:00 every 60 minutes, on); a malformed one fails.
    init?(json: [String: Any], base: BandSedentary? = nil) {
        var s = base ?? BandSedentary(enabled: true, intervalMinutes: 60, startHour: 9, startMinute: 0, endHour: 18, endMinute: 0)
        if let raw = json["enabled"] { guard let on = raw as? Bool else { return nil }; s.enabled = on }
        if let raw = json["interval_minutes"] {
            guard let minutes = (raw as? Int) ?? (raw as? Double).map(Int.init), (1...255).contains(minutes) else { return nil }
            s.intervalMinutes = minutes
        }
        if json["start"] != nil { guard let t = BandClock.parse(json["start"]) else { return nil }; (s.startHour, s.startMinute) = t }
        if json["end"] != nil { guard let t = BandClock.parse(json["end"]) else { return nil }; (s.endHour, s.endMinute) = t }
        self = s
    }

    init(enabled: Bool, intervalMinutes: Int, startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }
}

/// Units, clock and the auto-measure switches (`B8`), kept as the band's own two frames so a
/// write only ever changes the bytes asked for — the SDK writes the frame it read back with byte 1
/// set to `01`. Each switch byte is 0 (the band has no such feature), 1 (on) or 2 (off).
struct BandSettings: Equatable, Codable {
    /// Package 0: units, clock, auto heart rate / blood pressure / HRV, skin tone, music…
    var page1: [UInt8]
    /// Package 1: temperature unit and the auto temperature / glucose / stress switches.
    var page2: [UInt8]?

    /// The switches, by JSON name → (package, byte).
    static let switches: [(name: String, page: Int, index: Int)] = [
        ("auto_heart_rate", 1, 4), ("auto_blood_pressure", 1, 5), ("exercise", 1, 6), ("voice", 1, 7),
        ("find_phone_screen", 1, 8), ("stopwatch_screen", 1, 9), ("low_spo2_alert", 1, 10), ("auto_hrv", 1, 12),
        ("auto_answer", 1, 13), ("disconnect_alert", 1, 14), ("sos_alert", 1, 15), ("auto_ppg", 1, 16),
        ("music_control", 1, 18),
        ("long_press_unlock", 2, 2), ("message_screen_on", 2, 3), ("auto_temperature", 2, 4), ("ecg_always_on", 2, 6),
        ("auto_blood_glucose", 2, 7), ("met", 2, 8), ("auto_stress", 2, 9), ("auto_blood_component", 2, 11),
        ("fall_warning", 2, 14),
    ]

    /// The units the band keeps (Android SDK `CustomSetting`): page 2's bytes 5 temperature
    /// (1 °C, 2 °F), 10 blood glucose (1 mmol/L, 2 mg/dL), 12 uric acid (1 µmol/L, 2 mg/dL) and
    /// 13 blood fat (1 mmol/L, 2 mg/dL); page 1's byte 2 distance (1 metric, 2 imperial). 0 is a
    /// unit the band doesn't have.
    enum Unit: CaseIterable {
        case distance, temperature, glucose, uricAcid, bloodFat

        var place: (page: Int, index: Int) {
            switch self {
            case .distance: return (1, 2)
            case .temperature: return (2, 5)
            case .glucose: return (2, 10)
            case .uricAcid: return (2, 12)
            case .bloodFat: return (2, 13)
            }
        }
    }

    /// Whether the band's `unit` is metric; nil when it has no such unit.
    func isMetric(_ unit: Unit) -> Bool? {
        let (page, index) = unit.place
        guard let frame = page == 1 ? page1 : page2, frame.count > index, frame[index] != 0 else { return nil }
        return frame[index] == 1
    }

    /// These settings with `unit` set; nil when the band has no such unit.
    func with(_ unit: Unit, metric: Bool) -> BandSettings? {
        guard isMetric(unit) != nil else { return nil }
        let (page, index) = unit.place
        var next = self
        if page == 1 { next.page1[index] = metric ? 1 : 2 } else { next.page2?[index] = metric ? 1 : 2 }
        return next
    }

    init(page1: [UInt8], page2: [UInt8]? = nil) {
        self.page1 = Self.padded(page1)
        self.page2 = page2.map(Self.padded)
    }

    /// The E910's settings as it reported them on 2026-10-04 — a base for writes made before the
    /// band has been read (prefer the band's own frames).
    static let e910Default = BandSettings(
        page1: [0xB8, 0x02, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x02, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00],
        page2: [0xB8, 0x02, 0x00, 0x00, 0x02, 0x01, 0x00, 0x02, 0x00, 0x02, 0x01, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

    private static func padded(_ f: [UInt8]) -> [UInt8] {
        f.count >= BandProtocol.frameLength ? f : f + [UInt8](repeating: 0, count: BandProtocol.frameLength - f.count)
    }

    private func byte(_ page: Int, _ index: Int) -> UInt8? {
        let frame = page == 1 ? page1 : page2
        guard let frame, index < frame.count else { return nil }
        return frame[index]
    }

    private mutating func setByte(_ page: Int, _ index: Int, _ value: UInt8) {
        if page == 1 {
            if index < page1.count { page1[index] = value }
        } else if var frame = page2, index < frame.count {
            frame[index] = value
            page2 = frame
        }
    }

    /// nil when the band has no such switch.
    func isOn(_ name: String) -> Bool? {
        guard let s = Self.switches.first(where: { $0.name == name }), let b = byte(s.page, s.index), b != 0 else { return nil }
        return b == 1
    }

    /// Sets a switch the band has; one it lacks stays absent (the SDK refuses those too).
    mutating func set(_ name: String, _ on: Bool) {
        guard let s = Self.switches.first(where: { $0.name == name }), let b = byte(s.page, s.index), b != 0 else { return }
        setByte(s.page, s.index, on ? 1 : 2)
    }

    /// nil = no unit setting; true = metric.
    var metric: Bool? {
        get { byte(1, 2).flatMap { $0 == 0 ? nil : $0 == 1 } }
        set { if let newValue { setByte(1, 2, newValue ? 1 : 2) } }
    }

    /// Byte 3: 1 = 24-hour, 2 = 12-hour.
    var hour24: Bool {
        get { byte(1, 3) != 2 }
        set { setByte(1, 3, newValue ? 1 : 2) }
    }

    /// nil = no temperature feature; true = °C.
    var celsius: Bool? {
        get { byte(2, 5).flatMap { $0 == 0 ? nil : $0 == 1 } }
        set { if let newValue, byte(2, 5) != nil { setByte(2, 5, newValue ? 1 : 2) } }
    }

    /// Optical sensor skin-tone level (the SDK's "LED grade", byte 11); 0 = none.
    var skinTone: Int {
        get { Int(byte(1, 11) ?? 0) }
        set { setByte(1, 11, UInt8(max(0, min(255, newValue)))) }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["hour24": hour24]
        if let metric { out["units"] = metric ? "metric" : "imperial" }
        if let celsius { out["temperature_unit"] = celsius ? "c" : "f" }
        if skinTone > 0 { out["skin_tone"] = skinTone }
        for s in Self.switches { if let on = isOn(s.name) { out[s.name] = on } }
        return out
    }

    /// `json` laid over `base` (the band's last read). Unknown keys are ignored; a known key with
    /// the wrong type fails.
    init?(json: [String: Any], base: BandSettings) {
        var s = base
        if let raw = json["hour24"] { guard let v = raw as? Bool else { return nil }; s.hour24 = v }
        if let raw = json["units"] {
            guard let v = (raw as? String)?.lowercased(), ["metric", "imperial"].contains(v) else { return nil }
            s.metric = v == "metric"
        }
        if let raw = json["temperature_unit"] {
            guard let v = (raw as? String)?.lowercased(), ["c", "f"].contains(v) else { return nil }
            s.celsius = v == "c"
        }
        if let raw = json["skin_tone"] {
            guard let v = (raw as? Int) ?? (raw as? Double).map(Int.init), (1...6).contains(v) else { return nil }
            s.skinTone = v
        }
        for sw in Self.switches {
            guard let raw = json[sw.name] else { continue }
            guard let on = raw as? Bool else { return nil }
            s.set(sw.name, on)
        }
        self = s
    }
}

/// Phone-notification switches (`AD`): the band's own two packages, one state byte per app —
/// 0 = the band has no such app, 1 = on, 2 = off.
struct BandAlertSwitches: Equatable, Codable {
    /// Package 1, bytes 2…19, then package 2, bytes 2…7.
    static let apps1 = ["calls", "sms", "wechat", "qq", "sina", "facebook", "twitter", "flickr", "linkedin", "whatsapp",
                        "line", "instagram", "snapchat", "skype", "gmail", "dingtalk", "wechat_work", "others"]
    static let apps2 = ["tiktok", "telegram", "connected2", "kakaotalk", "jingyou", "messenger"]
    static var allApps: [String] { apps1 + apps2 }

    /// App name → 0 / 1 / 2.
    var states: [String: UInt8]

    init(states: [String: UInt8]) { self.states = states }

    func isOn(_ app: String) -> Bool? {
        guard let s = states[app], s != 0 else { return nil }
        return s == 1
    }

    mutating func set(_ app: String, _ on: Bool) {
        guard let s = states[app], s != 0 else { return }
        states[app] = on ? 1 : 2
    }

    var json: [String: Any] {
        var apps: [String: Bool] = [:]
        for app in Self.allApps where app != "calls" && app != "sms" { if let on = isOn(app) { apps[app] = on } }
        var out: [String: Any] = ["apps": apps]
        if let calls = isOn("calls") { out["calls"] = calls }
        if let sms = isOn("sms") { out["messages"] = sms }
        return out
    }

    /// `json` merged onto `base` (the band's current switches): `calls`, `messages` and `apps`
    /// ({name: Bool}). An app the band lacks stays off the wire; a wrong type fails.
    init?(json: [String: Any], base: BandAlertSwitches) {
        var s = base
        if let raw = json["calls"] { guard let on = raw as? Bool else { return nil }; s.set("calls", on) }
        if let raw = json["messages"] { guard let on = raw as? Bool else { return nil }; s.set("sms", on) }
        if let raw = json["apps"] {
            guard let apps = raw as? [String: Any] else { return nil }
            for (name, value) in apps {
                guard let on = value as? Bool else { return nil }
                s.set(name.lowercased(), on)
            }
        }
        self = s
    }
}
