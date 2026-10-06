import Foundation

// The units blood values are drawn in, app-wide, beside `TemperatureUnit`. Values are always
// kept canonical — mmol/L for glucose and blood fat, µmol/L for uric acid, °C — and converted
// only to show them. The band can hold the same choice (its `B8` settings, page 2), so its own
// app agrees; nothing it reports changes with it.

/// Blood glucose: mmol/L, or mg/dL (× 18.016).
enum GlucoseUnit: String, CaseIterable, Identifiable {
    case mmolL, mgdL

    static let key = "glucoseUnit"
    var id: String { rawValue }
    var label: String { self == .mmolL ? "mmol/L" : "mg/dL" }

    static var current: GlucoseUnit {
        UserDefaults.standard.string(forKey: key).flatMap(GlucoseUnit.init) ?? .mmolL
    }

    func value(_ mmol: Double) -> Double { self == .mmolL ? mmol : mmol * 18.016 }

    /// "5.6 mmol/L" / "101 mg/dL".
    func format(_ mmol: Double) -> String {
        self == .mmolL ? String(format: "%.1f %@", mmol, label) : String(format: "%.0f %@", value(mmol), label)
    }
}

/// Blood fat (cholesterol, HDL, LDL, triglycerides): mmol/L, or mg/dL. Cholesterol converts at
/// × 38.67, triglycerides at × 88.57.
enum BloodFatUnit: String, CaseIterable, Identifiable {
    case mmolL, mgdL

    static let key = "bloodFatUnit"
    var id: String { rawValue }
    var label: String { self == .mmolL ? "mmol/L" : "mg/dL" }

    static var current: BloodFatUnit {
        UserDefaults.standard.string(forKey: key).flatMap(BloodFatUnit.init) ?? .mmolL
    }

    /// `triglycerides` picks the triglyceride factor; everything else is cholesterol.
    func value(_ mmol: Double, triglycerides: Bool = false) -> Double {
        self == .mmolL ? mmol : mmol * (triglycerides ? 88.57 : 38.67)
    }

    func format(_ mmol: Double, triglycerides: Bool = false) -> String {
        self == .mmolL ? String(format: "%.2f %@", mmol, label)
            : String(format: "%.0f %@", value(mmol, triglycerides: triglycerides), label)
    }
}

/// Uric acid: µmol/L, or mg/dL (÷ 59.48).
enum UricAcidUnit: String, CaseIterable, Identifiable {
    case umolL, mgdL

    static let key = "uricAcidUnit"
    var id: String { rawValue }
    var label: String { self == .umolL ? "µmol/L" : "mg/dL" }

    static var current: UricAcidUnit {
        UserDefaults.standard.string(forKey: key).flatMap(UricAcidUnit.init) ?? .umolL
    }

    func value(_ umol: Double) -> Double { self == .umolL ? umol : umol / 59.48 }

    func format(_ umol: Double) -> String {
        self == .umolL ? String(format: "%.0f %@", umol, label) : String(format: "%.1f %@", value(umol), label)
    }
}
