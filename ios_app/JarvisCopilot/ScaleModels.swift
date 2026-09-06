import Foundation
import SwiftUI

// MARK: - Units

enum WeightUnit: String, CaseIterable, Identifiable, Codable {
    case kilograms = "kg", pounds = "lb", stones = "st"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Converts a kilogram value for display.
    func value(fromKg kg: Double) -> Double {
        switch self {
        case .kilograms: return kg
        case .pounds:    return kg * 2.2046226218
        case .stones:    return kg * 0.1574730444
        }
    }

    func kilograms(from value: Double) -> Double {
        switch self {
        case .kilograms: return value
        case .pounds:    return value / 2.2046226218
        case .stones:    return value / 0.1574730444
        }
    }

    /// Stones are conventionally shown as "11 st 4.2 lb".
    func format(kg: Double, decimals: Int = 1) -> String {
        switch self {
        case .stones:
            let totalLb = kg * 2.2046226218
            let st = Int(totalLb / 14)
            let lb = totalLb - Double(st) * 14
            return String(format: "%d st %.\(decimals)f lb", st, lb)
        default:
            return String(format: "%.\(decimals)f %@", value(fromKg: kg), rawValue)
        }
    }
}

enum HeightUnit: String, CaseIterable, Identifiable, Codable {
    case centimetres = "cm", feetInches = "ft"
    var id: String { rawValue }
    var label: String { self == .centimetres ? "cm" : "ft / in" }

    func format(cm: Double) -> String {
        switch self {
        case .centimetres:
            return String(format: "%.0f cm", cm)
        case .feetInches:
            let inches = cm / 2.54
            let ft = Int(inches / 12)
            let rem = inches - Double(ft) * 12
            return String(format: "%d' %.1f\"", ft, rem)
        }
    }
}

// MARK: - Profile

enum BiologicalSex: String, CaseIterable, Identifiable, Codable {
    case male, female
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Everything the body-composition algorithm needs about the person on the scale.
/// Mirrors the fields the stock app asks for when creating a member.
struct ScaleUserProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Me"
    var heightCm: Double = 175
    var birthday: Date = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    var sex: BiologicalSex = .male
    var athleteMode: Bool = false
    var goalWeightKg: Double? = nil
    /// Index of this user in the scale's own profile slots (P1…P10). Only some
    /// models store users on the scale.
    var scaleSlot: Int? = nil

    var age: Int {
        Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0
    }
}

// MARK: - Metrics

/// One body-composition figure. The list is exactly what the stock app's detail
/// screen shows for a full-body-composition scale.
enum BodyMetric: String, CaseIterable, Identifiable, Codable {
    case weight, bmi, bodyFat, fatFreeWeight, subcutaneousFat, visceralFat, bodyWater
    case skeletalMuscle, muscleMass, boneMass, protein, bmr, metabolicAge, heartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weight:          return "Weight"
        case .bmi:             return "BMI"
        case .bodyFat:         return "Body Fat"
        case .fatFreeWeight:   return "Fat-Free Weight"
        case .subcutaneousFat: return "Subcutaneous Fat"
        case .visceralFat:     return "Visceral Fat"
        case .bodyWater:       return "Body Water"
        case .skeletalMuscle:  return "Skeletal Muscle"
        case .muscleMass:      return "Muscle Mass"
        case .boneMass:        return "Bone Mass"
        case .protein:         return "Protein"
        case .bmr:             return "BMR"
        case .metabolicAge:    return "Metabolic Age"
        case .heartRate:       return "Heart Rate"
        }
    }

    var icon: String {
        switch self {
        case .weight:          return "scalemass"
        case .bmi:             return "figure.stand"
        case .bodyFat:         return "drop.fill"
        case .fatFreeWeight:   return "figure.walk"
        case .subcutaneousFat: return "circle.dashed"
        case .visceralFat:     return "circle.circle"
        case .bodyWater:       return "drop.triangle"
        case .skeletalMuscle:  return "figure.strengthtraining.traditional"
        case .muscleMass:      return "dumbbell.fill"
        case .boneMass:        return "bone"
        case .protein:         return "leaf.fill"
        case .bmr:             return "flame.fill"
        case .metabolicAge:    return "hourglass"
        case .heartRate:       return "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .weight:          return Color(red: 0.30, green: 0.62, blue: 1.0)
        case .bmi:             return Color(red: 0.55, green: 0.55, blue: 1.0)
        case .bodyFat:         return .orange
        case .fatFreeWeight:   return Color(red: 0.29, green: 0.82, blue: 0.49)
        case .subcutaneousFat: return Color(red: 1.0, green: 0.62, blue: 0.30)
        case .visceralFat:     return Color(red: 1.0, green: 0.42, blue: 0.35)
        case .bodyWater:       return Color(red: 0.35, green: 0.78, blue: 1.0)
        case .skeletalMuscle:  return Color(red: 0.66, green: 0.40, blue: 1.0)
        case .muscleMass:      return Color(red: 0.72, green: 0.48, blue: 1.0)
        case .boneMass:        return Color(red: 0.85, green: 0.85, blue: 0.75)
        case .protein:         return Color(red: 0.45, green: 0.85, blue: 0.60)
        case .bmr:             return Color(red: 1.0, green: 0.50, blue: 0.20)
        case .metabolicAge:    return Color(red: 0.80, green: 0.70, blue: 0.40)
        case .heartRate:       return Color(red: 1.0, green: 0.31, blue: 0.40)
        }
    }

    /// Whether the value is a mass, so it follows the user's weight unit.
    var isMass: Bool {
        switch self {
        case .weight, .fatFreeWeight, .muscleMass, .boneMass: return true
        default: return false
        }
    }

    /// Unit suffix for non-mass metrics.
    var fixedUnit: String {
        switch self {
        case .bmi, .visceralFat: return ""
        case .bodyFat, .subcutaneousFat, .bodyWater, .skeletalMuscle, .protein: return "%"
        case .bmr:             return "kcal"
        case .metabolicAge:    return "yrs"
        case .heartRate:       return "bpm"
        default:               return ""
        }
    }

    /// Metrics that only exist when the scale measured impedance.
    var needsImpedance: Bool {
        switch self {
        case .weight, .bmi, .heartRate: return false
        default: return true
        }
    }

    func format(_ value: Double, unit: WeightUnit) -> String {
        if isMass { return unit.format(kg: value) }
        switch self {
        case .bmi:                         return String(format: "%.1f", value)
        case .visceralFat:                 return String(format: "%.0f", value)
        case .bmr, .metabolicAge, .heartRate:
            return String(format: "%.0f %@", value, fixedUnit)
        default:                           return String(format: "%.1f%@", value, fixedUnit)
        }
    }

    /// Bare number without a unit, for large readouts.
    func number(_ value: Double, unit: WeightUnit) -> String {
        if isMass { return String(format: "%.1f", unit.value(fromKg: value)) }
        switch self {
        case .bmr, .metabolicAge, .heartRate, .visceralFat: return String(format: "%.0f", value)
        default: return String(format: "%.1f", value)
        }
    }
}

// MARK: - Readings

/// One completed weighing. Masses are stored in kilograms regardless of the unit the
/// scale or the user prefers; conversion is display-only.
struct ScaleReading: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var profileID: UUID?
    var model: String
    var deviceID: String
    var weightKg: Double
    /// Whole-body impedance in ohms, when the scale measured it.
    var impedance: Double?
    var heartRate: Int?
    /// Derived body-composition figures, keyed by metric. Weight and BMI are always
    /// present; the rest need impedance and a profile.
    var metrics: [BodyMetric: Double]
    /// How the scale reported the weight; kept so the record can be shown in the
    /// unit the person saw on the display.
    var scaleUnit: WeightUnit
    /// Baby-mode readings hold the difference between two weighings.
    var isBabyMode: Bool = false

    static func == (a: ScaleReading, b: ScaleReading) -> Bool { a.id == b.id }
}

// MARK: - History store

/// Local weighing history, one JSON file in Application Support. The stock app syncs
/// to VeSync's cloud; here the phone is the source of truth, and Jarvis reads it
/// through the bridge.
@MainActor
final class ScaleHistoryStore: ObservableObject {
    static let shared = ScaleHistoryStore()

    @Published private(set) var readings: [ScaleReading] = []
    @Published var profiles: [ScaleUserProfile] = [] { didSet { saveProfiles() } }
    @Published var activeProfileID: UUID? {
        didSet { UserDefaults.standard.set(activeProfileID?.uuidString, forKey: "scaleActiveProfile") }
    }

    private let readingsURL: URL
    private let profilesURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("JarvisCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        readingsURL = base.appendingPathComponent("scale-readings.json")
        profilesURL = base.appendingPathComponent("scale-profiles.json")
        load()
    }

    var activeProfile: ScaleUserProfile? {
        get { profiles.first { $0.id == activeProfileID } ?? profiles.first }
        set {
            guard let newValue else { return }
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[i] = newValue
            } else {
                profiles.append(newValue)
            }
            activeProfileID = newValue.id
        }
    }

    func readings(for profile: UUID?) -> [ScaleReading] {
        readings.filter { $0.profileID == profile }.sorted { $0.date > $1.date }
    }

    func latest(for profile: UUID?) -> ScaleReading? { readings(for: profile).first }

    func add(_ reading: ScaleReading) {
        readings.append(reading)
        readings.sort { $0.date > $1.date }
        saveReadings()
    }

    func delete(_ reading: ScaleReading) {
        readings.removeAll { $0.id == reading.id }
        saveReadings()
    }

    func delete(ids: Set<UUID>) {
        readings.removeAll { ids.contains($0.id) }
        saveReadings()
    }

    /// Moves a guest reading onto a profile, the stock app's "assign to user".
    func assign(_ reading: ScaleReading, to profile: UUID) {
        guard let i = readings.firstIndex(where: { $0.id == reading.id }) else { return }
        readings[i].profileID = profile
        saveReadings()
    }

    func replace(_ reading: ScaleReading) {
        guard let i = readings.firstIndex(where: { $0.id == reading.id }) else { return }
        readings[i] = reading
        saveReadings()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: readingsURL),
           let list = try? JSONDecoder().decode([ScaleReading].self, from: data) {
            readings = list.sorted { $0.date > $1.date }
        }
        if let data = try? Data(contentsOf: profilesURL),
           let list = try? JSONDecoder().decode([ScaleUserProfile].self, from: data) {
            profiles = list
        }
        if profiles.isEmpty { profiles = [ScaleUserProfile()] }
        if let raw = UserDefaults.standard.string(forKey: "scaleActiveProfile"),
           let id = UUID(uuidString: raw), profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id
        }
    }

    private func saveReadings() {
        if let data = try? JSONEncoder().encode(readings) {
            try? data.write(to: readingsURL, options: .atomic)
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
    }
}
