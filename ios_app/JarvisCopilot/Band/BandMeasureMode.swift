import Foundation

/// How the band works a reading out — G Band's "General" and "Private". General is the band's
/// population estimate; Private measures against the person's own reference stored on the band
/// (a cuff reading, meter readings, a lab test — the calibrations in the band's settings), the
/// SDK's private blood-pressure and calibrated glucose/blood-component readings — or, for the
/// readings the band can't calibrate, against a real device's reading kept on the phone.
enum BandMeasureMode: String, CaseIterable, Codable {
    case general, `private`

    var label: String { self == .general ? "General" : "Private" }

    /// The start/stop frame's mode byte for the band-side three: `90 01 01`, `89 01 01 01`,
    /// `8A 01 01 01`. The others are calibrated on the phone (`BandReferenceCalibration`).
    var byte: UInt8 { self == .private ? 1 : 0 }

    private static func key(_ type: BandMeasure) -> String { "band.measureMode.\(type.rawValue)" }

    /// The mode picked last for `type` — what every reading of it uses: the band's page, Jarvis's
    /// `band_measure` and scheduled readings. General for readings without a private mode.
    static func saved(for type: BandMeasure, in defaults: UserDefaults = .standard) -> BandMeasureMode {
        guard type.hasModes else { return .general }
        return defaults.string(forKey: key(type)).flatMap(Self.init(rawValue:)) ?? .general
    }

    static func save(_ mode: BandMeasureMode, for type: BandMeasure, in defaults: UserDefaults = .standard) {
        guard type.hasModes else { return }
        defaults.set(mode.rawValue, forKey: key(type))
    }
}

extension BandMeasure {
    /// The readings the band can take against a personal reference.
    var hasPrivateMode: Bool { self == .bloodPressure || self == .bloodGlucose || self == .bloodComponent }
}

/// A reading the band can't calibrate itself (heart rate, SpO₂, temperature, stress, body fat)
/// calibrated on the phone: a real device's value next to the band's, taken together. Private
/// readings move by the difference.
struct BandReferenceCalibration: Equatable, Codable {
    /// What the real device read (temperature in °C, whatever unit it was typed in).
    var reference: Double
    /// What the band read at the same time, in General mode terms.
    var band: Double
    var date: Date

    var offset: Double { reference - band }

    private static func key(_ type: BandMeasure) -> String { "band.referenceCalibration.\(type.rawValue)" }

    static func saved(for type: BandMeasure, in defaults: UserDefaults = .standard) -> BandReferenceCalibration? {
        guard type.calibratesOnPhone, let data = defaults.data(forKey: key(type)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ c: BandReferenceCalibration?, for type: BandMeasure, in defaults: UserDefaults = .standard) {
        guard type.calibratesOnPhone else { return }
        guard let c, let data = try? JSONEncoder().encode(c) else { defaults.removeObject(forKey: key(type)); return }
        defaults.set(data, forKey: key(type))
    }
}

extension BandMeasure {
    /// Calibrated by the phone, not the band: everything but the band-side three and the ECG
    /// (a rhythm, not one number).
    var calibratesOnPhone: Bool { !hasPrivateMode && self != .ecg }

    /// Every reading with a General/Private choice.
    var hasModes: Bool { hasPrivateMode || calibratesOnPhone }

    /// The real device a phone-side calibration compares with.
    var referenceDevice: String {
        switch self {
        case .heartRate: return "a chest strap or pulse oximeter"
        case .bloodOxygen: return "a pulse oximeter"
        case .temperature: return "a thermometer"
        case .stress: return "another stress tracker"
        case .bodyComposition: return "a body-fat scale"
        default: return "a reference device"
        }
    }

    /// The unit the reference is typed in (temperature in the person's own unit; the editor
    /// stores °C).
    var referenceUnit: String {
        switch self {
        case .heartRate: return "bpm"
        case .bloodOxygen: return "%"
        case .temperature: return TemperatureUnit.current == .fahrenheit ? "°F" : "°C"
        case .stress: return ""
        case .bodyComposition: return "% body fat"
        default: return ""
        }
    }
}

extension BandReading {
    /// The one number a phone-side calibration moves (temperature in °C, as stored).
    var referenceValue: Double? {
        switch measure {
        case .heartRate: return heartRate.map(Double.init)
        case .bloodOxygen: return spo2.map(Double.init)
        case .temperature: return temperatureC
        case .stress: return stress.map(Double.init)
        case .bodyComposition: return bodyComposition?.bodyFatPercent
        default: return nil
        }
    }

    /// This reading moved by `c` (a Private reading the band can't calibrate).
    func calibrated(by c: BandReferenceCalibration) -> BandReading {
        var r = self
        let d = c.offset
        switch measure {
        case .heartRate: r.heartRate = heartRate.map { max(30, $0 + Int(d.rounded())) }
        case .bloodOxygen: r.spo2 = spo2.map { min(100, max(70, $0 + Int(d.rounded()))) }
        case .temperature: r.temperatureC = temperatureC.map { $0 + d }
        case .stress: r.stress = stress.map { min(100, max(0, $0 + Int(d.rounded()))) }
        case .bodyComposition: r.bodyComposition?.bodyFatPercent += d
        default: break
        }
        return r
    }
}
