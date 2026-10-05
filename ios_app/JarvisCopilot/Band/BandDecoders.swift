import Foundation

// Decoders for the band's replies. Each takes whole frames, opcode included, so `f[n]` is the
// SDK's `bz[n]`. History (daily, sleep, workouts) lives in BandHistory.swift.

/// The `A1` reply.
struct BandHandshake: Equatable, Codable {
    /// 6 "successfulVerification" or 1 "passTheVerification"; 0 is a wrong PIN.
    var ack: Int
    var ok: Bool { ack == 1 || ack == 6 }
    /// "00.07.02.00-2713": four version bytes as hex, then the device id.
    var firmware: String
    var deviceId: Int
    var mac: String
    /// nil when the band has no such feature.
    var raiseToWake: Bool?
    var findPhone: Bool?
    var wearDetection: Bool?

    var json: [String: Any] {
        var out: [String: Any] = ["ok": ok, "ack": ack, "firmware": firmware, "device_id": deviceId, "mac": mac]
        if let raiseToWake { out["raise_to_wake"] = raiseToWake }
        if let findPhone { out["find_phone"] = findPhone }
        if let wearDetection { out["wear_detection"] = wearDetection }
        return out
    }
}

/// The five `A7` feature packages: the SDK's field name → its type value (0 = absent).
struct BandFeatures: Equatable, Codable {
    var types: [String: Int]
    /// Raw frames by package number (1…5).
    var packages: [Int: [UInt8]]

    static let package1 = ["bloodPressureType", "drinkingAlcoholType", "healthTipsType", "skinColorType", "WechatCampaignType",
                           "cameraType", "fatigueType", "bloodOxygenType", "tipPackType", "heartRateAlarmType", "brightScreenType",
                           "femaleType", "brightnessAdjustmentType", "", "precisionWatchType", "highEndBloodPressureType",
                           "alarmClockType", "heartRateFunctionType"]
    static let package2 = ["countdownTimeType", "dailyDataReadDayType", "informationPushType", "HIDFunctionType",
                           "modeOfMotionStorageNumberType", "UIStyleType", "respiratoryRateFunctionType", "HRVType",
                           "weatherFunctionType", "newAgreementUploadType", "", "screenDurationType", "sleepFlagBitType",
                           "clearDataBitsType", "ECGFunction", "motionModeType", "lowPowerType", "TPType"]
    static let package3 = ["transferProcessType", "dialNumberType", "agingTestType", "addressBookType", "bootPageType",
                           "musicFunctionType", "bodyTemperatureFunctionType", "lookupFunctionType", "AGPFunctionType",
                           "GPSFunctionType", "geomagneticFunctionType", "resetPasswordFunctionType",
                           "testMicrophoneFunctionType", "broadcastingFunctionType", "bloodGlucoseFunction", "chipSeriesType",
                           "metaFunctionType", "pressureFunctionType"]
    static let package4 = ["bloodComponentType", "bodyCompositionType", "worldClockType", "bodyTemperatureAlarmType",
                           "walletType", "businessCardType", "gameFeatureType", "alQuestionAndAnswerType", "alDialType",
                           "distanceAndCalorieType", "videoDialType", "b3AutoTestFeatureType", "DAMotionContrlType",
                           "photoAlbumPhotosType", "4GFeatureType", "electronicBusinessCardType", "healthAssistanceType",
                           "microCheckType"]

    /// Capability names the skills use → the SDK field that gates them.
    static let capabilities: [(name: String, key: String)] = [
        ("heart_rate", "heartRateFunctionType"), ("blood_pressure", "bloodPressureType"), ("spo2", "bloodOxygenType"),
        ("spo2_auto", "b3AutoTestFeatureType"), ("ecg", "ECGFunction"), ("hrv", "HRVType"),
        ("temperature", "bodyTemperatureFunctionType"), ("blood_glucose", "bloodGlucoseFunction"),
        ("blood_component", "bloodComponentType"), ("body_composition", "bodyCompositionType"),
        ("stress", "pressureFunctionType"), ("met", "metaFunctionType"), ("camera", "cameraType"),
        ("raise_to_wake", "brightScreenType"), ("alarms", "alarmClockType"), ("find", "lookupFunctionType"),
        ("music", "musicFunctionType"), ("sport_control", "DAMotionContrlType"), ("sport_records", "motionModeType"),
        ("heart_rate_alarm", "heartRateAlarmType"), ("skin_tone", "skinColorType"), ("phone_alerts", "informationPushType"),
        ("health_tips", "healthTipsType"), ("sedentary", "tipPackType"), ("reset_password", "resetPasswordFunctionType"),
        ("clear_data", "clearDataBitsType"), ("daily_data", "dailyDataReadDayType"), ("precise_sleep", "sleepFlagBitType"),
    ]

    /// A capability name ("ecg") or an SDK field ("ECGFunction"). Heart rate is the one inverted
    /// field: its type 1 means "no heart rate", every other value is a sensor variant.
    func supports(_ name: String) -> Bool {
        let key = Self.capabilities.first(where: { $0.name == name.lowercased() })?.key ?? name
        guard let value = types[key] else { return false }
        return key == "heartRateFunctionType" ? value != 1 : value != 0
    }

    var supported: [String] { Self.capabilities.map(\.name).filter(supports) }

    var json: [String: Any] { ["supported": supported, "types": types] }
}

/// The `A0` reply.
struct BandBattery: Equatable, Codable {
    /// 0–100. When the band reports a level (0–4) instead, the level × 25.
    var percent: Int
    var charging: Bool
    /// On the charger and full.
    var full: Bool
    var low: Bool
    var lowVoltage: Bool
    var percentValid: Bool

    /// The shared shape the ring screens use; on the charger counts as charging.
    var ring: RingBattery { RingBattery(percent: percent, charging: charging || full) }

    var json: [String: Any] {
        ["percent": percent, "charging": charging || full, "full": full, "low": low || lowVoltage]
    }
}

/// The three `FC` production-info frames.
struct BandProduct: Equatable, Codable {
    /// As the SDK prints it: bytes 6…3 of the first frame, hex ("3730314a").
    var module: String
    /// The same bytes in wire order as text ("J107").
    var moduleName: String
    var hardwareVersion: Int
    /// "00.02".
    var firmwareVersion: String
    /// "00.00.00.00.00.00".
    var touchPanelVersion: String

    var json: [String: Any] {
        ["module": module, "module_name": moduleName, "hardware_version": hardwareVersion,
         "firmware_version": firmwareVersion, "touch_panel_version": touchPanelVersion]
    }
}

struct BandBloodComponent: Equatable, Codable {
    var uricAcid: Double
    var cholesterol: Double
    var triglycerides: Double
    var hdl: Double
    var ldl: Double

    var json: [String: Any] {
        ["uric_acid_umol_l": uricAcid, "cholesterol_mmol_l": cholesterol, "triglycerides_mmol_l": triglycerides,
         "hdl_mmol_l": hdl, "ldl_mmol_l": ldl]
    }
}

/// One frame of an on-demand measurement.
struct BandReading: Equatable {
    enum Status: String, Codable {
        case done, measuring, failed
        case notWorn = "not_worn"
        case busy
    }

    var measure: BandMeasure
    var date: Date
    var status: Status
    /// 0–100 where the band reports progress.
    var progress: Int?
    var heartRate: Int?
    var systolic: Int?
    var diastolic: Int?
    var spo2: Int?
    var temperatureC: Double?
    var surfaceTemperatureC: Double?
    var stress: Int?
    var hrv: Int?
    var bloodGlucose: Double?
    var bloodComponent: BandBloodComponent?
    /// The band's own state byte, for logs.
    var state: Int?

    var finished: Bool { status == .done }
    var notWorn: Bool { status == .notWorn }
    var busy: Bool { status == .busy }

    var json: [String: Any] {
        var out: [String: Any] = ["type": measure.name, "status": status.rawValue,
                                  "time": ISO8601DateFormatter().string(from: date)]
        if let progress { out["progress"] = progress }
        if let heartRate { out["heart_rate"] = heartRate }
        if let systolic { out["systolic"] = systolic }
        if let diastolic { out["diastolic"] = diastolic }
        if let spo2 { out["spo2"] = spo2 }
        if let temperatureC { out["temperature_c"] = temperatureC }
        if let surfaceTemperatureC { out["surface_temperature_c"] = surfaceTemperatureC }
        if let stress { out["stress"] = stress }
        if let hrv { out["hrv"] = hrv }
        if let bloodGlucose { out["blood_glucose_mmol_l"] = bloodGlucose }
        if let bloodComponent { out.merge(bloodComponent.json) { a, _ in a } }
        return out
    }
}

/// `D8` (steps, distance, energy) or `A8` (steps only).
struct BandSteps: Equatable, Codable {
    var daysAgo: Int
    var steps: Int
    var distanceMeters: Int?
    /// As the band sends it; the SDK passes it on unscaled.
    var calories: Int?

    var json: [String: Any] {
        var out: [String: Any] = ["days_ago": daysAgo, "steps": steps]
        if let distanceMeters { out["distance_m"] = distanceMeters }
        if let calories { out["calories"] = calories }
        return out
    }
}

/// A `DA 02` status reply or a `DA 03` report the band sends on its own during an app sport.
struct BandSportStatus: Equatable, Codable {
    enum RunState: String, Codable { case notStarted = "not_started", exercising, paused, unknown }
    enum DeviceState: String, Codable { case normal, lowBattery = "low_battery", charging, maxDuration = "max_duration", batteryCritical = "battery_critical", unknown }

    /// The band sent it unprompted (a report carries only mode, op code and heart rate).
    var report: Bool
    var success: Bool
    var sportMode: Int?
    /// 1 start, 2 pause, 3 resume, 4 stop, 5 data report.
    var opCode: Int?
    var runState: RunState?
    var deviceState: DeviceState?
    var elapsedSeconds: Int?
    var distanceMeters: Int?
    var heartRate: Int?
    /// Small calories (the SDK demo divides by 1000 for kcal).
    var calories: Int?
    /// Seconds per km.
    var paceSecondsPerKm: Int?
    /// Metres per hour.
    var speedMetersPerHour: Int?
    var gnss: Bool?
    /// 0 no signal … 4 strong.
    var gnssSignal: Int?

    var json: [String: Any] {
        var out: [String: Any] = ["report": report, "success": success]
        if let sportMode { out["sport_mode"] = sportMode }
        if let opCode { out["op_code"] = opCode }
        if let runState { out["run_state"] = runState.rawValue }
        if let deviceState { out["device_state"] = deviceState.rawValue }
        if let elapsedSeconds { out["elapsed_s"] = elapsedSeconds }
        if let distanceMeters { out["distance_m"] = distanceMeters }
        if let heartRate { out["heart_rate"] = heartRate }
        if let calories { out["kcal"] = Double(calories) / 1000 }
        if let paceSecondsPerKm { out["pace_s_per_km"] = paceSecondsPerKm }
        if let speedMetersPerHour { out["speed_km_h"] = Double(speedMetersPerHour) / 1000 }
        if let gnss { out["gnss"] = gnss }
        return out
    }
}

struct BandHeartRateAlarm: Equatable, Codable {
    var enabled: Bool
    var high: Int
    var low: Int
}

struct BandRaiseToWake: Equatable, Codable {
    var enabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var level: Int
    var defaultLevel: Int
}

/// The automatic SpO₂ window (`B3`).
struct BandOxygenSchedule: Equatable, Codable {
    var enabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
}

/// What a `B5` frame says.
enum BandFindEvent: String, Codable {
    /// The band is buzzing.
    case searching
    /// The wearer pressed the band, or the search was stopped.
    case found
    case timeout
    case unsupported
    /// The band is asking the phone to ring (find my phone).
    case phoneWanted = "phone_wanted"
}

/// `B6` camera-remote replies.
struct BandCameraEvent: Equatable, Codable {
    var ok: Bool
    /// 0 left the camera screen, 1 entered it, 2 the wearer pressed the shutter.
    var state: Int
    var shutter: Bool { state == 2 || bandAsked }
    /// Byte 3: the band asked the phone to take a picture.
    var bandAsked: Bool
}

enum BandDecode {
    // MARK: Helpers

    static func opcode(_ f: [UInt8]) -> UInt8 { f.first ?? 0 }

    static func at(_ f: [UInt8], _ i: Int) -> Int { i >= 0 && i < f.count ? Int(f[i]) : 0 }
    static func le16(_ f: [UInt8], _ i: Int) -> Int { at(f, i) | at(f, i + 1) << 8 }
    static func be16(_ f: [UInt8], _ i: Int) -> Int { at(f, i) << 8 | at(f, i + 1) }
    static func le32(_ f: [UInt8], _ i: Int) -> Int { at(f, i) | at(f, i + 1) << 8 | at(f, i + 2) << 16 | at(f, i + 3) << 24 }
    static func be32(_ f: [UInt8], _ i: Int) -> Int { at(f, i) << 24 | at(f, i + 1) << 16 | at(f, i + 2) << 8 | at(f, i + 3) }

    private static func hex(_ b: UInt8) -> String { String(format: "%02x", b) }

    // MARK: Session

    static func password(_ f: [UInt8]) -> BandHandshake? {
        guard f.count >= 20, f[0] == BandOp.password else { return nil }
        let deviceId = be16(f, 4)
        let firmware = f[6..<10].map(hex).joined(separator: ".") + "-\(deviceId)"
        let mac = f[12..<18].reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
        func flag(_ b: UInt8) -> Bool? { b == 1 ? true : b == 2 ? false : nil }
        return BandHandshake(ack: Int(f[3]), firmware: firmware, deviceId: deviceId, mac: mac,
                             raiseToWake: f[11] == 1 ? true : f[11] == 0 ? false : nil,
                             findPhone: flag(f[18]), wearDetection: flag(f[19]))
    }

    static func features(_ frames: [[UInt8]]) -> BandFeatures {
        var types: [String: Int] = [:]
        var packages: [Int: [UInt8]] = [:]
        for f in frames where f.count >= 20 && f[0] == BandOp.features {
            let package = Int(f[19])
            packages[package] = f
            let names: [String]
            switch package {
            case 1: names = BandFeatures.package1
            case 2: names = BandFeatures.package2
            case 3: names = BandFeatures.package3
            case 4: names = BandFeatures.package4
            default: continue
            }
            for (i, name) in names.enumerated() where !name.isEmpty { types[name] = Int(f[i + 1]) }
        }
        return BandFeatures(types: types, packages: packages)
    }

    /// Byte 1: 0 normal, 1 charging, 2 low, 3 full; byte 5 says byte 6 is a percentage; byte 7
    /// is 1 unless the cell voltage is low.
    static func battery(_ f: [UInt8]) -> BandBattery? {
        guard f.count >= 8, f[0] == BandOp.battery, f[1] <= 3 else { return nil }
        let valid = f[5] != 0
        let percent = valid ? min(100, Int(f[6])) : min(100, Int(f[6]) * 25)
        return BandBattery(percent: percent, charging: f[1] == 1, full: f[1] == 3, low: f[1] == 2,
                           lowVoltage: f[7] != 1, percentValid: valid)
    }

    /// Complete once the frame with byte 18 = 3 has arrived.
    static func product(_ frames: [[UInt8]]) -> BandProduct? {
        var module = "", name = "", firmware = "", tp = ""
        var hardware = 0
        var done = false
        for f in frames where f.count >= 20 && f[0] == BandOp.product {
            switch f[18] {
            case 1:
                module = [f[6], f[5], f[4], f[3]].map(hex).joined()
                name = String(decoding: f[3...6].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                hardware = Int(f[7])
                firmware = hex(f[9]) + "." + hex(f[8])
            case 2: tp = f[9...14].map(hex).joined(separator: ".")
            case 3: done = true
            default: break
            }
        }
        guard done, !module.isEmpty else { return nil }
        return BandProduct(module: module, moduleName: name, hardwareVersion: hardware, firmwareVersion: firmware,
                           touchPanelVersion: tp)
    }

    /// The read reply's two packages (byte 19: 0, then 1). Write acks (`B8 01`) are skipped.
    static func settings(_ frames: [[UInt8]]) -> BandSettings? {
        var page1: [UInt8]?, page2: [UInt8]?
        for f in frames where f.count >= 20 && f[0] == BandOp.settings && f[1] != 0x01 {
            if f[19] == 0 { page1 = f } else if f[19] == 1 { page2 = f }
        }
        return page1.map { BandSettings(page1: $0, page2: page2) }
    }

    /// Package 2 ends `00 10`; anything else is package 1.
    static func alerts(_ frames: [[UInt8]]) -> BandAlertSwitches? {
        var states: [String: UInt8] = [:]
        var any = false
        for f in frames where f.count >= 20 && f[0] == BandOp.alerts {
            let second = f[18] == 0 && f[19] == 0x10
            let names = second ? BandAlertSwitches.apps2 : BandAlertSwitches.apps1
            for (i, name) in names.enumerated() { states[name] = f[i + 2] <= 2 ? f[i + 2] : 0 }
            any = true
        }
        return any ? BandAlertSwitches(states: states) : nil
    }

    /// Simple acknowledgements: true = done, false = refused, nil = not an ack this knows.
    static func ack(_ f: [UInt8]) -> Bool? {
        guard let op = f.first, f.count >= 2 else { return nil }
        switch op {
        case BandOp.profile: return f[1] != 0
        case BandOp.syncTime: return f[1] == 1
        case BandOp.settings where f[1] == 0x01: return true
        case BandOp.alarms where f[1] == 0x01 || f[1] == 0x02: return true
        case BandOp.sedentary: return f[1] == 1
        case BandOp.heartRateAlarm: return at(f, 3) == 1
        case BandOp.raiseToWake: return f[1] == 1
        case BandOp.bloodOxygenAuto: return f[1] == 1
        case BandOp.camera: return f[1] == 1
        case BandOp.factoryReset: return at(f, 2) == 1
        case BandOp.sportControl where f[1] == 0x01: return at(f, 2) == 1
        default: return nil
        }
    }

    // MARK: Measurements

    /// The band's busy / not-worn state byte shared by blood pressure (byte 4): 0 idle, 1–5 a
    /// test running (1 BP, 2 HR, 3 the 5-minute auto test, 4 SpO₂, 5 fatigue), FC not worn,
    /// FD charging, FE low battery, FF busy.
    private static func pressureState(_ b: UInt8) -> Int {
        switch b {
        case 0...5: return Int(b)
        case 0xFC: return 6
        case 0xFD: return 7
        case 0xFE: return 8
        case 0xFF: return 9
        default: return Int(b)
        }
    }

    /// Glucose / blood component / stress ack byte: 0 usable, 1 and 3 busy, 2 low battery, 4 not worn.
    private static func measureAck(_ b: Int) -> BandReading.Status? {
        switch b {
        case 1, 2, 3: return .busy
        case 4: return .notWorn
        default: return nil
        }
    }

    /// One frame of a measurement stream. Heart rate and SpO₂ stream until stopped; a value in
    /// range makes the frame `done`. The others report progress and finish at 100.
    static func measurement(_ f: [UInt8], at date: Date = Date()) -> BandReading? {
        guard let op = f.first, f.count >= 2 else { return nil }
        switch op {
        case BandOp.heartRate:
            // d0 <hr> <heart state> .. .. <watch state>: busy first, then not worn (hr 1), then
            // a value only in 30…250 (the SDK's rule; 0 is "no value yet").
            let hr = at(f, 1), watch = at(f, 5)
            var r = BandReading(measure: .heartRate, date: date, status: .measuring, state: watch)
            if watch != 0 && watch != 2 { r.status = .busy } else if hr == 1 { r.status = .notWorn } else if (30...250).contains(hr) {
                r.heartRate = hr
                r.status = .done
            }
            return r
        case BandOp.bloodOxygen:
            // 80 01 <state> <value>: state 0 or 4 is fine, anything else busy; value 1 = not worn.
            let state = at(f, 2), value = at(f, 3)
            var r = BandReading(measure: .bloodOxygen, date: date, status: .measuring, state: state)
            if state != 0 && state != 4 { r.status = .busy } else if value == 1 { r.status = .notWorn } else if (70...100).contains(value) {
                r.spo2 = value
                r.status = .done
            }
            return r
        case BandOp.bloodPressure:
            // 90 sys dia progress state hasProgress. 30/20 at 100 % is the band's failure value.
            let state = pressureState(UInt8(at(f, 4)))
            var r = BandReading(measure: .bloodPressure, date: date, status: .measuring, state: state)
            switch state {
            case 6: r.status = .notWorn; return r
            case 7, 8, 9: r.status = .busy; return r
            case 2...5: r.status = .busy; return r
            default: break
            }
            guard at(f, 5) != 0 else { return r }
            r.progress = at(f, 3)
            if r.progress == 100 {
                if at(f, 1) == 30 && at(f, 2) == 20 { r.status = .failed } else {
                    r.systolic = at(f, 1)
                    r.diastolic = at(f, 2)
                    r.status = .done
                }
            }
            return r
        case BandOp.temperature:
            // 87 01 <on> <status> <progress> body(LE, 0.1 °C) surface(LE): status 0 or 7 is
            // measuring; otherwise the band is busy with another test (8 low battery).
            let status = at(f, 3)
            var r = BandReading(measure: .temperature, date: date, status: .measuring, state: status)
            guard status == 0 || status == 7 else { r.status = .busy; return r }
            r.progress = at(f, 4)
            if r.progress == 100 {
                r.temperatureC = Double(le16(f, 5)) / 10
                r.surfaceTemperatureC = Double(le16(f, 7)) / 10
                r.status = .done
            }
            return r
        case BandOp.glucoseStress where at(f, 1) == 6:
            // 89 06 <control> <ack> <progress> <stress>.
            var r = BandReading(measure: .stress, date: date, status: .measuring, progress: at(f, 4), state: at(f, 3))
            if let s = measureAck(at(f, 3)) { r.status = s; return r }
            if r.progress == 100 { r.stress = at(f, 5); r.status = .done }
            return r
        case BandOp.glucoseStress where at(f, 1) == 1:
            // 89 01 <1 on | 2 off> <ack> <progress> <glucose LE / 100>.
            var r = BandReading(measure: .bloodGlucose, date: date, status: .measuring, state: at(f, 3))
            if at(f, 2) == 2 { return r }   // the stop ack
            if let s = measureAck(at(f, 3)) { r.status = s; return r }
            r.progress = at(f, 4)
            if r.progress == 100 { r.bloodGlucose = Double(le16(f, 5)) / 100; r.status = .done }
            return r
        case BandOp.bloodComponent where at(f, 1) == 1:
            var r = BandReading(measure: .bloodComponent, date: date, status: .measuring, state: at(f, 3))
            if at(f, 2) == 0 { r.status = measureAck(at(f, 3)) ?? .measuring; return r }   // the stop ack
            if let s = measureAck(at(f, 3)) { r.status = s; return r }
            r.progress = at(f, 4)
            if r.progress == 100 {
                r.bloodComponent = BandBloodComponent(uricAcid: Double(le16(f, 5)) / 10, cholesterol: Double(le16(f, 7)) / 100,
                                                      triglycerides: Double(le16(f, 9)) / 100, hdl: Double(le16(f, 11)) / 100,
                                                      ldl: Double(le16(f, 13)) / 100)
                r.status = .done
            }
            return r
        case BandOp.ecgBody where at(f, 1) == 1:
            // ECG data type 1 (byte 3): per-second figures — heart rate per minute (byte 6), HRV
            // (byte 7, FF none), wear (byte 12, 1 not worn), band state (byte 4: 2 charging,
            // 3 low battery), progress (byte 19).
            guard at(f, 3) == 1 || at(f, 3) == 0 else { return nil }
            var r = BandReading(measure: .ecg, date: date, status: .measuring, progress: at(f, 19), state: at(f, 4))
            guard at(f, 3) == 1 else { return r }
            if at(f, 4) == 2 || at(f, 4) == 3 { r.status = .busy; return r }
            if at(f, 12) == 1 { r.status = .notWorn; return r }
            if (30...250).contains(at(f, 6)) { r.heartRate = at(f, 6) }
            if at(f, 7) != 0xFF, at(f, 7) > 0 { r.hrv = at(f, 7) }
            if r.progress == 100 { r.status = .done }
            return r
        case BandOp.ecgBody where at(f, 1) == 4:
            // Body composition progress frame (data type 0); the result frames are not decoded.
            guard at(f, 3) == 0 else { return nil }
            return BandReading(measure: .bodyComposition, date: date, status: at(f, 4) >= 100 ? .done : .measuring,
                               progress: at(f, 4), state: at(f, 5))
        default:
            return nil
        }
    }

    // MARK: Steps

    static func steps(_ f: [UInt8]) -> BandSteps? {
        guard let op = f.first else { return nil }
        if op == BandOp.steps, f.count >= 14 {
            return BandSteps(daysAgo: at(f, 1), steps: le32(f, 2), distanceMeters: le32(f, 6), calories: le32(f, 10))
        }
        if op == BandOp.stepCount, f.count >= 6 {
            let raw = be32(f, 1)
            guard raw != 0xFFFF_FFFF else { return nil }
            return BandSteps(daysAgo: at(f, 5), steps: raw)
        }
        return nil
    }

    // MARK: Sport control

    /// The `DA 01` reply: did the band take the start / pause / resume / stop.
    static func sportAck(_ f: [UInt8]) -> Bool? {
        guard f.count >= 3, f[0] == BandOp.sportControl, f[1] == 0x01 else { return nil }
        return f[2] == 1
    }

    /// `DA 02` (status read) or `DA 03` (band report): TLVs after byte 4, several frames when
    /// an `A0` header says so (`A0 len <total>`, byte 3 the frame number).
    static func sportStatus(_ frames: [[UInt8]]) -> BandSportStatus? {
        var pending: [UInt8] = []
        var result: BandSportStatus?
        for f in frames where f.count >= 4 && f[0] == BandOp.sportControl && (f[1] == 2 || f[1] == 3) {
            let body = Array(f[4...])
            let total = body.count >= 3 && body[0] == 0xA0 ? Int(body[2]) : 1
            let index = Int(f[3])
            if total > 1 && index < total { pending += body; continue }
            let all = pending.isEmpty ? body : pending + body
            pending = []
            result = sportTLV(all, report: f[1] == 3, success: f[2] == 1)
        }
        return result
    }

    private static func sportTLV(_ p: [UInt8], report: Bool, success: Bool) -> BandSportStatus {
        var s = BandSportStatus(report: report, success: success)
        var i = 0
        while i < p.count - 1 {
            let tag = p[i], length = Int(p[i + 1])
            guard i + 2 + length <= p.count else { break }
            let v = Array(p[(i + 2)..<(i + 2 + length)])
            switch tag {
            case 0xA1: s.sportMode = le16(v, 0)
            case 0xA2: s.opCode = at(v, 0)
            case 0xA3: s.runState = [0: .notStarted, 1: .exercising, 2: .paused][at(v, 0)] ?? .unknown
            case 0xA4: s.deviceState = [0: .normal, 1: .lowBattery, 2: .charging, 3: .maxDuration, 4: .batteryCritical][at(v, 0)] ?? .unknown
            case 0xA5: s.elapsedSeconds = le32(v, 0)
            case 0xA6: s.distanceMeters = le32(v, 0)
            case 0xA7: s.heartRate = at(v, 0)
            case 0xA8: s.calories = le32(v, 0)
            case 0xA9: s.paceSecondsPerKm = le16(v, 0)
            case 0xAA: s.speedMetersPerHour = le16(v, 0)
            case 0xAB: s.gnss = at(v, 0) == 1; s.gnssSignal = at(v, 1)
            default: break
            }
            i += 2 + length
        }
        return s
    }

    // MARK: Controls

    /// `B5 0A|0B <state>`: true while the band is buzzing; false once found, stopped or timed out.
    static func find(_ f: [UInt8]) -> Bool? {
        guard let event = findEvent(f) else { return nil }
        switch event {
        case .searching: return true
        case .found, .timeout, .unsupported: return false
        case .phoneWanted: return nil
        }
    }

    static func findEvent(_ f: [UInt8]) -> BandFindEvent? {
        guard f.count >= 2, f[0] == BandOp.find else { return nil }
        if f[1] == 0x00 { return .phoneWanted }
        guard f[1] == 0x0A || f[1] == 0x0B else { return nil }
        switch at(f, 2) {
        case 1: return .searching
        case 2: return .found
        case 3: return .timeout
        default: return .unsupported
        }
    }

    static func camera(_ f: [UInt8]) -> BandCameraEvent? {
        guard f.count >= 4, f[0] == BandOp.camera else { return nil }
        return BandCameraEvent(ok: f[1] == 1, state: Int(f[2]), bandAsked: f[3] == 1)
    }

    /// The `B9 03` read reply: every `A1` record after the header (the SDK starts looking past
    /// byte 4 of the payload), `A1 len B1 08 id on days hh mm … B2 n label`.
    static func alarms(_ frames: [[UInt8]]) -> [BandAlarm] {
        var out: [BandAlarm] = []
        for f in frames where f.count >= 4 && f[0] == BandOp.alarms && (3...5).contains(f[1]) {
            let p = Array(f[4...])
            for (i, b) in p.enumerated() where b == 0xA1 && i > 4 {
                guard i + 1 < p.count else { continue }
                let end = min(p.count, i + Int(p[i + 1]) + 2)
                let r = Array(p[i..<end])
                guard r.count >= 9 else { continue }
                var label = ""
                if r.count > 13, r[12] == 0xB2, r[13] != 0 {
                    let n = min(Int(r[13]), r.count - 14)
                    label = String(decoding: r[14..<(14 + n)], as: UTF8.self).replacingOccurrences(of: "\0", with: "")
                }
                out.append(BandAlarm(id: Int(r[4]), hour: Int(r[7]), minute: Int(r[8]), days: BandWeekday.days(r[6]),
                                     enabled: r[5] != 0, label: label))
            }
        }
        return out
    }

    /// `E1 ack sh sm eh em interval on control`; nil unless the ack is 1 (0 failed, 2 no such feature).
    static func sedentary(_ f: [UInt8]) -> BandSedentary? {
        guard f.count >= 8, f[0] == BandOp.sedentary, f[1] == 1 else { return nil }
        return BandSedentary(enabled: f[7] != 0, intervalMinutes: Int(f[6]), startHour: Int(f[2]), startMinute: Int(f[3]),
                             endHour: Int(f[4]), endMinute: Int(f[5]))
    }

    /// `AC max min ack op state`.
    static func heartRateAlarm(_ f: [UInt8]) -> BandHeartRateAlarm? {
        guard f.count >= 6, f[0] == BandOp.heartRateAlarm, f[3] == 1 else { return nil }
        return BandHeartRateAlarm(enabled: f[5] != 0, high: Int(f[1]), low: Int(f[2]))
    }

    /// `AA ack control sh sm eh em on level default`.
    static func raiseToWake(_ f: [UInt8]) -> BandRaiseToWake? {
        guard f.count >= 10, f[0] == BandOp.raiseToWake, f[1] == 1 else { return nil }
        return BandRaiseToWake(enabled: f[7] == 1, startHour: Int(f[3]), startMinute: Int(f[4]), endHour: Int(f[5]),
                               endMinute: Int(f[6]), level: Int(f[8]), defaultLevel: Int(f[9]))
    }

    /// `B3 ack .. .. sh sm eh em on`.
    static func bloodOxygenAuto(_ f: [UInt8]) -> BandOxygenSchedule? {
        guard f.count >= 9, f[0] == BandOp.bloodOxygenAuto, f[1] == 1 else { return nil }
        return BandOxygenSchedule(enabled: f[8] == 1, startHour: Int(f[4]), startMinute: Int(f[5]), endHour: Int(f[6]),
                                  endMinute: Int(f[7]))
    }

    /// `D3 01|02 ok crc0 crc1 crc2` (LE): one CRC per stored-workout slot; 02 is the band's own
    /// report after a workout ends.
    static func sportCRCs(_ f: [UInt8]) -> [Int]? {
        guard f.count >= 9, f[0] == BandOp.sportCRC, f[2] == 1 else { return nil }
        return [le16(f, 3), le16(f, 5), le16(f, 7)]
    }

    // MARK: Framing

    /// Whether the frames received so far answer `request` completely.
    static func isComplete(_ frames: [[UInt8]], for request: [UInt8]) -> Bool {
        guard let op = request.first else { return true }
        let mine = frames.filter { $0.first == op }
        switch op {
        case BandOp.password:
            return !mine.isEmpty
        case BandOp.daily:
            return mine.contains { $0.count >= 3 && $0[1] == 0xFF && $0[2] == 0xFF }
        case BandOp.sleep:
            return mine.contains { $0.count >= 2 && $0[1] == 0 }
        case BandOp.product:
            return mine.contains { $0.count >= 19 && $0[18] == 3 }
        case BandOp.settings where request.count > 1 && request[1] == 0x02:
            return mine.contains { $0.count >= 20 && $0[19] == 0 } && mine.contains { $0.count >= 20 && $0[19] == 1 }
        case BandOp.alerts where request.count > 1 && request[1] == 0x02:
            return mine.contains { $0.count >= 20 && $0[18] == 0 && $0[19] == 0x10 }
        case BandOp.sportRecords:
            return mine.contains {
                let pkt = le16($0, 1), total = le16($0, 3)
                return total == 0 || (pkt == total && pkt > 3)
            }
        case BandOp.sportControl where request.count > 1 && request[1] == 0x02:
            return mine.contains { f in
                guard f.count >= 4, f[1] == 2 else { return false }
                let total = f.count >= 7 && f[4] == 0xA0 ? Int(f[6]) : 1
                return !(total > 1 && Int(f[3]) < total)
            }
        default:
            return !mine.isEmpty
        }
    }
}
