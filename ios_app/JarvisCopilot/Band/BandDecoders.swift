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

    /// A capability name ("ecg") or an SDK field ("ECGFunction"). Most fields: any type but 0.
    /// The exceptions are the Android SDK's (its A7 parser): heart rate's type 1 means "none";
    /// stress and MET exist only as types 2–3; glucose type 3 is calibration only; body
    /// composition is type 1; HRV type 5 is none; SpO₂ is the listed sensor types.
    func supports(_ name: String) -> Bool {
        let key = Self.capabilities.first(where: { $0.name == name.lowercased() })?.key ?? name
        guard let value = types[key] else { return false }
        switch key {
        case "heartRateFunctionType": return value != 1
        case "pressureFunctionType", "metaFunctionType": return value == 2 || value == 3
        case "bloodGlucoseFunction": return value != 0 && value != 3
        case "bodyCompositionType": return value == 1
        case "HRVType": return value != 0 && value != 5
        case "bloodOxygenType": return (1...9).contains(value) || [0xFD, 0xFE, 0xE0].contains(value)
        default: return value != 0
        }
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

/// The body-composition result: 14 figures, each sent ×10, little-endian, after two header
/// bytes (`A0 1C`) of the joined result parts. Units as the SDK docs give them.
struct BandBodyComposition: Equatable, Codable {
    var bmi: Double
    var bodyFatPercent: Double
    var fatMassKg: Double
    var leanMassKg: Double
    var musclePercent: Double
    var muscleMassKg: Double
    var subcutaneousFatPercent: Double
    var bodyWaterPercent: Double
    var waterKg: Double
    var skeletalMusclePercent: Double
    var boneMassKg: Double
    var proteinPercent: Double
    var proteinKg: Double
    var basalMetabolismKcal: Double

    /// nil when the parts are too short or carry no BMI (no result).
    init?(_ data: [UInt8]) {
        guard data.count >= 30 else { return nil }
        let v = (0..<14).map { Double(BandDecode.le16(data, 2 + $0 * 2)) / 10 }
        guard v[0] > 0 else { return nil }
        bmi = v[0]; bodyFatPercent = v[1]; fatMassKg = v[2]; leanMassKg = v[3]; musclePercent = v[4]
        muscleMassKg = v[5]; subcutaneousFatPercent = v[6]; bodyWaterPercent = v[7]; waterKg = v[8]
        skeletalMusclePercent = v[9]; boneMassKg = v[10]; proteinPercent = v[11]; proteinKg = v[12]
        basalMetabolismKcal = v[13]
    }

    var json: [String: Any] {
        ["bmi": bmi, "body_fat_percent": bodyFatPercent, "fat_mass_kg": fatMassKg, "lean_mass_kg": leanMassKg,
         "muscle_percent": musclePercent, "muscle_mass_kg": muscleMassKg, "subcutaneous_fat_percent": subcutaneousFatPercent,
         "body_water_percent": bodyWaterPercent, "water_kg": waterKg, "skeletal_muscle_percent": skeletalMusclePercent,
         "bone_mass_kg": boneMassKg, "protein_percent": proteinPercent, "protein_kg": proteinKg,
         "basal_metabolism_kcal": basalMetabolismKcal]
    }
}

/// One frame of a result the band sends over several: part `index` of `total` and its 14 bytes.
struct BandResultPart: Equatable {
    var index: Int
    var total: Int
    var data: [UInt8]
}

/// One frame of an on-demand measurement, or (from `BandMeasureRun`) the reading it ended as.
struct BandReading: Equatable {
    enum Status: String, Codable {
        case done, measuring, failed
        case notWorn = "not_worn"
        case busy
    }

    /// Why a reading ended without a value, for people to read.
    enum Reason {
        static let busy = "The band is busy (another reading or a sync) — try again in a minute."
        static let notWorn = "The band isn't on a wrist."
        static let charging = "The band is charging."
        static let lowBattery = "The band's battery is too low."
        static let failed = "The band couldn't get a reading — keep still and try again."
        static let noReading = "No reading — keep still and try again."
        static let unsupported = "This band can't take that reading."
        static let sensor = "The band's sensor reported a fault."
        static let leadOff = "Keep the band on and a finger on its electrode until the reading ends."
        static let silent = "The band stopped answering."
        static func outOfTime(_ seconds: TimeInterval) -> String {
            "Out of time — this reading takes up to \(Int(seconds)) s."
        }
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
    /// Breaths per minute (ECG).
    var respiratoryRate: Int?
    var bloodGlucose: Double?
    var bloodComponent: BandBloodComponent?
    var bodyComposition: BandBodyComposition?
    /// ECG: the band's whole diagnosis (QTc, QRS, ST, SDNN/RMSSD, risks, findings).
    var ecg: BandEcgDiagnosis?
    /// ECG: the QTc the band reports each second while it runs (ms).
    var qtcMs: Int?
    /// Why it ended without a value (failed, busy, not worn).
    var failure: String?
    /// ECG / body composition: no finger on the electrode right now (the reading carries on).
    var leadOff = false
    /// A frame that is one part of a result sent over several; `BandMeasureRun` joins them.
    var part: BandResultPart?
    /// The band's own state byte, for logs.
    var state: Int?

    var finished: Bool { status == .done }
    var notWorn: Bool { status == .notWorn }
    var busy: Bool { status == .busy }
    /// Done, failed, busy or not worn: nothing more is coming.
    var ended: Bool { status != .measuring }

    /// Ends the reading as `status`, saying why.
    mutating func end(_ status: Status, _ why: String) {
        self.status = status
        failure = why
    }

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
        if let respiratoryRate { out["respiratory_rate"] = respiratoryRate }
        if let bloodGlucose { out["blood_glucose_mmol_l"] = bloodGlucose }
        if let bloodComponent { out.merge(bloodComponent.json) { a, _ in a } }
        if let bodyComposition { out.merge(bodyComposition.json) { a, _ in a } }
        if let qtcMs { out["qtc_ms"] = qtcMs }
        if let ecg {
            out.merge(ecg.extra.mapValues { $0 as Any }) { a, _ in a }
            out["rhythm"] = ecg.rhythm
            let findings = ecg.findings
            if !findings.isEmpty { out["findings"] = findings.map { ["name": $0.name, "grade": $0.gradeWord] } }
        }
        if let failure { out["failure"] = failure }
        if leadOff { out["lead_off"] = true }
        return out
    }
}

/// One spot reading as it streams in, joined into the reading it ends as: a result the band
/// splits over several frames (body composition, the ECG diagnosis) put back together, the
/// ECG's figures carried to its end frame, and the endings the band leaves to the app — the
/// SDK docs say to end an electrode reading once its lead is lost more than four times, and a
/// reading that goes quiet, keeps its lead off or runs past its deadline ends as `failed`.
struct BandMeasureRun {
    let measure: BandMeasure
    let started: Date
    let deadline: Date
    /// The caller's time is shorter than the reading's own.
    let shortened: Bool
    var stallAfter: TimeInterval = 25
    var leadOffLimit: TimeInterval = 20
    static let leadLossLimit = 4

    /// The reading so far; the one it ended as once `ended`.
    private(set) var reading: BandReading?
    private(set) var lastFrame: Date?
    private(set) var leadOffSince: Date?
    private(set) var leadLosses = 0
    private var parts: [Int: [UInt8]] = [:]

    var ended: Bool { reading?.ended ?? false }

    /// `seconds` caps the reading's own `timeout`.
    init(_ measure: BandMeasure, from start: Date, seconds: TimeInterval? = nil) {
        self.measure = measure
        started = start
        let budget = min(seconds ?? measure.timeout, measure.timeout)
        deadline = start.addingTimeInterval(budget)
        shortened = budget < measure.timeout
    }

    /// One frame's reading (others' and anything after the end are ignored).
    mutating func add(_ frame: BandReading, at now: Date) {
        guard frame.measure == measure, !ended else { return }
        lastFrame = now
        var r = frame
        if r.progress == nil { r.progress = reading?.progress }
        if measure.usesElectrode, !r.ended, r.part == nil {
            if r.leadOff {
                if leadOffSince == nil { leadOffSince = now; leadLosses += 1 }
            } else {
                leadOffSince = nil
            }
            if leadLosses > Self.leadLossLimit { r.end(.failed, BandReading.Reason.leadOff) }
        }
        if let part = r.part { join(part, into: &r) }
        if measure == .ecg, !r.ended || r.finished {
            // The live figures, then the averages, then the diagnosis: the latest carries on.
            r.heartRate = r.heartRate ?? reading?.heartRate
            r.hrv = r.hrv ?? reading?.hrv
            r.respiratoryRate = r.respiratoryRate ?? reading?.respiratoryRate
            r.qtcMs = r.qtcMs ?? reading?.qtcMs
            // The diagnosis comes in its parts before the band's "success": keep it to the end.
            r.ecg = r.ecg ?? reading?.ecg
        }
        // The band's own "failed" right after the lead came off: that was why.
        if measure.usesElectrode, r.status == .failed, r.failure == BandReading.Reason.failed, reading?.leadOff == true {
            r.failure = BandReading.Reason.leadOff
        }
        reading = r
    }

    /// The time-based endings, checked as the reading runs.
    mutating func tick(at now: Date) {
        guard !ended else { return }
        if now >= deadline {
            let why = reading?.leadOff == true ? BandReading.Reason.leadOff
                : shortened ? BandReading.Reason.outOfTime(measure.timeout) : BandReading.Reason.noReading
            end(.failed, why, at: now)
        } else if now.timeIntervalSince(lastFrame ?? started) > stallAfter {
            end(.failed, BandReading.Reason.silent, at: now)
        } else if let off = leadOffSince, now.timeIntervalSince(off) > leadOffLimit {
            end(.failed, BandReading.Reason.leadOff, at: now)
        }
    }

    /// Ends it now, keeping the progress but no values.
    mutating func end(_ status: BandReading.Status, _ why: String, at now: Date) {
        guard !ended else { return }
        var r = BandReading(measure: measure, date: now, status: status, progress: reading?.progress,
                            state: reading?.state)
        r.leadOff = reading?.leadOff ?? false
        r.failure = why
        reading = r
    }

    /// The last part completes a result; a gap in the parts fails it.
    private mutating func join(_ part: BandResultPart, into r: inout BandReading) {
        parts[part.index] = part.data
        guard part.index >= part.total else { return }
        let all = (1...max(1, part.total)).compactMap { parts[$0] }
        parts = [:]
        guard all.count == part.total else { r.end(.failed, BandReading.Reason.failed); return }
        let data = all.flatMap { $0 }
        switch measure {
        case .bodyComposition:
            if let result = BandBodyComposition(data) {
                r.bodyComposition = result
                r.status = .done
            } else {
                r.end(.failed, BandReading.Reason.failed)
            }
        case .ecg:
            r.ecg = BandEcgDiagnosis(data)
            // The diagnosis: lead-off type, eight diagnosis bytes, heart rate, breathing, HRV, QT.
            if (30...250).contains(BandDecode.at(data, 9)) { r.heartRate = BandDecode.at(data, 9) }
            if BandDecode.at(data, 10) > 0 { r.respiratoryRate = BandDecode.at(data, 10) }
            if (1...254).contains(BandDecode.at(data, 11)) { r.hrv = BandDecode.at(data, 11) }
        default:
            break
        }
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

    private typealias Refusal = (status: BandReading.Status, why: String)

    /// The state byte blood pressure (byte 4) and SpO₂ (byte 2) carry, as the SDK docs list it:
    /// 0 idle, 1 a blood-pressure test, 2 heart rate, 3 the five-minute auto test, 4 SpO₂,
    /// 5 fatigue, FC not worn, FD charging, FE low battery, FF busy. `free` = carry on.
    private static func bandState(_ b: Int, free: Set<Int>) -> Refusal? {
        if free.contains(b) { return nil }
        switch b {
        case 0xFC: return (.notWorn, BandReading.Reason.notWorn)
        case 0xFD: return (.failed, BandReading.Reason.charging)
        case 0xFE: return (.failed, BandReading.Reason.lowBattery)
        default: return (.busy, BandReading.Reason.busy)
        }
    }

    /// The ack byte stress, glucose and blood components share: 0 usable, 1 a test of the same
    /// kind already running (for glucose: its own test, which is fine), 2 low battery, 3 another
    /// test, 4 not worn. Unknown codes fail glucose and blood components (the Android SDK) and
    /// are ignored for stress.
    private static func measureAck(_ b: Int, sameTestIsFine: Bool = false, unknownFails: Bool = true) -> Refusal? {
        switch b {
        case 0: return nil
        case 1: return sameTestIsFine ? nil : (.busy, BandReading.Reason.busy)
        case 2: return (.failed, BandReading.Reason.lowBattery)
        case 3: return (.busy, BandReading.Reason.busy)
        case 4: return (.notWorn, BandReading.Reason.notWorn)
        default: return unknownFails ? (.failed, BandReading.Reason.failed) : nil
        }
    }

    /// One frame of a measurement stream. Heart rate and SpO₂ stream until stopped and end at
    /// their first value; the rest end on the band's own result or refusal. A reading the band
    /// ends without a value carries `failure`. Rules from the Android SDK's parsers (JADX,
    /// vpprotocol 2.3.86) checked against the WeChat SDK's; where they differ it says so.
    static func measurement(_ f: [UInt8], at date: Date = Date()) -> BandReading? {
        guard let op = f.first, f.count >= 2 else { return nil }
        switch op {
        case BandOp.heartRate: return heartRate(f, date)
        case BandOp.bloodOxygen: return bloodOxygen(f, date)
        case BandOp.bloodPressure: return bloodPressure(f, date)
        case BandOp.temperature: return temperature(f, date)
        case BandOp.glucoseStress where at(f, 1) == 6: return stress(f, date)
        case BandOp.glucoseStress where at(f, 1) == 1: return bloodGlucose(f, date)
        case BandOp.bloodComponent where at(f, 1) == 1: return bloodComponent(f, date)
        case BandOp.ecgBody where at(f, 1) == 1: return ecg(f, date)
        case BandOp.ecgBody where at(f, 1) == 4: return bodyComposition(f, date)
        default: return nil
        }
    }

    /// `d0 <hr> <heart state> .. .. <watch state>` about once a second until stopped. Busy first
    /// (watch state other than 0, 2 or 3 — the WeChat SDK counts 3 busy too), then not worn (hr
    /// 1, or 2 in Android), then a value in 30…250; 0 is "no value yet".
    private static func heartRate(_ f: [UInt8], _ date: Date) -> BandReading {
        let hr = at(f, 1), watch = at(f, 5)
        var r = BandReading(measure: .heartRate, date: date, status: .measuring, state: watch)
        if ![0, 2, 3].contains(watch) {
            r.end(.busy, BandReading.Reason.busy)
        } else if hr == 1 || hr == 2 {
            r.end(.notWorn, BandReading.Reason.notWorn)
        } else if (30...250).contains(hr) {
            r.heartRate = hr
            r.status = .done
        }
        return r
    }

    /// `80 <0 none | 1 on | 2 off> <state> <value> <checking 1|2> <progress>` until stopped.
    /// State 0 or 4 is free, anything else busy (FC/FD/FE read as the blood-pressure table has
    /// them); value 1 is not worn, 70…100 a reading.
    private static func bloodOxygen(_ f: [UInt8], _ date: Date) -> BandReading {
        let state = at(f, 2), value = at(f, 3)
        var r = BandReading(measure: .bloodOxygen, date: date, status: .measuring, state: state)
        if at(f, 4) == 1 || at(f, 4) == 2 { r.progress = at(f, 5) }
        if at(f, 1) == 0 {
            r.end(.failed, BandReading.Reason.unsupported)
        } else if at(f, 1) == 2 {
            return r   // the stop ack
        } else if let refusal = bandState(state, free: [0, 4]) {
            r.end(refusal.status, refusal.why)
        } else if value == 1 {
            r.end(.notWorn, BandReading.Reason.notWorn)
        } else if (70...100).contains(value) {
            r.spo2 = value
            r.status = .done
        }
        return r
    }

    /// `90 <sys> <dia> <progress> <state> <has progress>`, 50–55 s to 100 %. The state byte
    /// refuses (1, 2, 4, 5, FF another test — 3, the auto test, is fine). At 100 % 30/20 is the
    /// band's "measurement failed" and 0 no reading. A band without progress (byte 5 = 0) sends
    /// its values once, at the end.
    private static func bloodPressure(_ f: [UInt8], _ date: Date) -> BandReading {
        let sys = at(f, 1), dia = at(f, 2), state = at(f, 4)
        var r = BandReading(measure: .bloodPressure, date: date, status: .measuring, state: state)
        if let refusal = bandState(state, free: [0, 3]) {
            r.end(refusal.status, refusal.why)
            return r
        }
        if at(f, 5) == 1 {
            r.progress = at(f, 3)
            guard at(f, 3) >= 100 else { return r }
        } else if sys == 0 && dia == 0 {
            return r
        }
        if (sys == 30 && dia == 20) || sys == 0 || dia == 0 {
            r.end(.failed, BandReading.Reason.failed)
        } else {
            r.systolic = sys
            r.diastolic = dia
            r.progress = 100
            r.status = .done
        }
        return r
    }

    /// `87 01 <0 none | 1 on | 2 off> <state> <progress> <body LE> <surface LE>` in 0.1 °C. State
    /// 0 or 7 (the band's own auto test) is fine, 1–6 another test, 8 low battery, 9 a sensor
    /// fault. The values come at 100 %; a body temperature of 0 is no reading.
    private static func temperature(_ f: [UInt8], _ date: Date) -> BandReading {
        let state = at(f, 3)
        var r = BandReading(measure: .temperature, date: date, status: .measuring, state: state)
        switch at(f, 2) {
        case 0: r.end(.failed, BandReading.Reason.unsupported); return r
        case 2: return r   // the stop ack
        default: break
        }
        switch state {
        case 0, 7: break
        case 8: r.end(.failed, BandReading.Reason.lowBattery); return r
        case 9: r.end(.failed, BandReading.Reason.sensor); return r
        default: r.end(.busy, BandReading.Reason.busy); return r
        }
        r.progress = at(f, 4)
        guard at(f, 4) >= 100 else { return r }
        let body = Double(le16(f, 5)) / 10
        if body > 0 {
            r.temperatureC = body
            r.surfaceTemperatureC = Double(le16(f, 7)) / 10
            r.status = .done
        } else {
            r.end(.failed, BandReading.Reason.failed)
        }
        return r
    }

    /// `89 06 <0 none | 1 on | 2 off> <ack> <progress> <stress>`. Done at 100 % with a value
    /// above 0 — the Android SDK reports no success without one.
    private static func stress(_ f: [UInt8], _ date: Date) -> BandReading {
        var r = BandReading(measure: .stress, date: date, status: .measuring, state: at(f, 3))
        switch at(f, 2) {
        case 0: r.end(.failed, BandReading.Reason.unsupported); return r
        case 2: return r   // the stop ack
        default: break
        }
        if let refusal = measureAck(at(f, 3), unknownFails: false) { r.end(refusal.status, refusal.why); return r }
        r.progress = at(f, 4)
        guard at(f, 4) >= 100 else { return r }
        if at(f, 5) > 0 { r.stress = at(f, 5); r.status = .done } else { r.end(.failed, BandReading.Reason.failed) }
        return r
    }

    /// `89 01 <0 none | 1 on | 2 off> <ack> <progress> <value LE>`: the low 13 bits are mmol/L ×
    /// 100 (the top 3 a risk level on some bands). Ack 1 is its own test running (Android; the
    /// WeChat SDK calls it busy).
    private static func bloodGlucose(_ f: [UInt8], _ date: Date) -> BandReading {
        var r = BandReading(measure: .bloodGlucose, date: date, status: .measuring, state: at(f, 3))
        switch at(f, 2) {
        case 0: r.end(.failed, BandReading.Reason.unsupported); return r
        case 2: return r   // the stop ack
        default: break
        }
        if let refusal = measureAck(at(f, 3), sameTestIsFine: true) { r.end(refusal.status, refusal.why); return r }
        r.progress = at(f, 4)
        guard at(f, 4) >= 100 else { return r }
        let value = le16(f, 5) & 0x1FFF
        if value > 0 { r.bloodGlucose = Double(value) / 100; r.status = .done } else { r.end(.failed, BandReading.Reason.failed) }
        return r
    }

    /// `8a 01 <1 on | 0 or 2 off> <ack> <progress> <uric acid, cholesterol, triglycerides, HDL,
    /// LDL LE>`: uric acid in 0.1 µmol/L, the rest in 0.01 mmol/L. All zero at 100 % is no reading.
    private static func bloodComponent(_ f: [UInt8], _ date: Date) -> BandReading {
        var r = BandReading(measure: .bloodComponent, date: date, status: .measuring, state: at(f, 3))
        guard at(f, 2) == 1 else { return r }   // the stop ack: 00 (WeChat SDK) or 02 (Android)
        if let refusal = measureAck(at(f, 3)) { r.end(refusal.status, refusal.why); return r }
        r.progress = at(f, 4)
        guard at(f, 4) >= 100 else { return r }
        let blood = BandBloodComponent(uricAcid: Double(le16(f, 5)) / 10, cholesterol: Double(le16(f, 7)) / 100,
                                       triglycerides: Double(le16(f, 9)) / 100, hdl: Double(le16(f, 11)) / 100,
                                       ldl: Double(le16(f, 13)) / 100)
        if (5..<15).contains(where: { at(f, $0) != 0 }) {
            r.bloodComponent = blood
            r.status = .done
        } else {
            r.end(.failed, BandReading.Reason.failed)
        }
        return r
    }

    /// `93 01 <1 on | 2 off> <type> …`. Type 0: the sampling rate. Type 1, each second: band
    /// state (byte 4), heart rate per minute (6), HRV (7, FF none), lead (12: 1 = not touching —
    /// the SDKs call it wear; iOS "lead off"), progress (19). Type 2: averages (heart rate 13,
    /// breathing 14, HRV 15). Type 5: part of the diagnosis (byte 4 of byte 5, 14 bytes from
    /// byte 6). Type 4: done — the figures are the ones before it; type 3: failed.
    private static func ecg(_ f: [UInt8], _ date: Date) -> BandReading? {
        // Neither SDK reads byte 2 here (the stop's reply is gated off by the session).
        var r = BandReading(measure: .ecg, date: date, status: .measuring, state: at(f, 4))
        switch at(f, 3) {
        case 0:
            r.progress = at(f, 19)
        case 1:
            r.progress = at(f, 19)
            // Band state: 0 free, 1 a PPG test, 2 / FD charging, 3 / EF low battery, FC not worn.
            switch at(f, 4) {
            case 0: break
            case 2, 0xFD: r.end(.failed, BandReading.Reason.charging); return r
            case 3, 0xEF: r.end(.failed, BandReading.Reason.lowBattery); return r
            case 0xFC: r.end(.notWorn, BandReading.Reason.notWorn); return r
            default: r.end(.busy, BandReading.Reason.busy); return r
            }
            // EcgDetectState: hr1, hr2 (5, 6), HRV (7), breathing (10, 11), wear (12), QTc (14–15 LE).
            r.leadOff = at(f, 12) == 1
            if (30...250).contains(at(f, 6)) { r.heartRate = at(f, 6) }
            if (1...254).contains(at(f, 7)) { r.hrv = at(f, 7) }
            if at(f, 11) > 0 { r.respiratoryRate = at(f, 11) }
            let qtc = at(f, 14) | at(f, 15) << 8
            if (200...700).contains(qtc) { r.qtcMs = qtc }
        case 2:
            r.progress = at(f, 19)
            if (30...250).contains(at(f, 13)) { r.heartRate = at(f, 13) }
            if at(f, 14) > 0 { r.respiratoryRate = at(f, 14) }
            if (1...254).contains(at(f, 15)) { r.hrv = at(f, 15) }
        case 3:
            r.end(.failed, BandReading.Reason.failed)
        case 4:
            r.progress = 100
            r.status = .done
        case 5:
            r.part = part(f)
        default:
            return nil
        }
        return r
    }

    /// `93 04 <1 on | 2 off> <state> …`: state 0 progress (byte 4) and the electrode lead (byte
    /// 5: 0 a finger on it, 1 off); 1 a result part (byte 4 of byte 5, 14 bytes from byte 6);
    /// 2 failed (no result), 3 busy, 4 low battery.
    private static func bodyComposition(_ f: [UInt8], _ date: Date) -> BandReading {
        var r = BandReading(measure: .bodyComposition, date: date, status: .measuring, state: at(f, 3))
        if at(f, 2) == 2 { return r }   // the stop ack
        switch at(f, 3) {
        case 0:
            r.progress = at(f, 4)
            r.leadOff = at(f, 5) == 1
        case 1: r.part = part(f)
        case 2: r.end(.failed, at(f, 5) == 1 ? BandReading.Reason.leadOff : BandReading.Reason.failed)
        case 3: r.end(.busy, BandReading.Reason.busy)
        case 4: r.end(.failed, BandReading.Reason.lowBattery)
        default: r.end(.failed, BandReading.Reason.failed)
        }
        return r
    }

    /// A result part: index (byte 4) of total (byte 5), then 14 data bytes.
    private static func part(_ f: [UInt8]) -> BandResultPart {
        BandResultPart(index: at(f, 4), total: at(f, 5), data: (6..<20).map { UInt8(at(f, $0)) })
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
