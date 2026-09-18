import SwiftUI

/// A metric the Health tab shows and keeps history for. The raw value is the
/// server's name for it (`/health/history?metric=`).
enum HealthMetric: String, CaseIterable, Identifiable, Hashable {
    case battery, steps, sleep
    case sleepDebt = "sleep_debt"
    case heartRate = "heart_rate"
    case spo2, hrv, stress, temperature
    /// Minutes of workouts a day.
    case exercise

    var id: String { rawValue }

    /// How a history chart draws it.
    enum Style { case range, bars, stacked, line, bandBars }

    var title: String {
        switch self {
        case .battery: return HealthScores.batteryName
        case .steps: return "Steps"
        case .sleep: return "Sleep"
        case .sleepDebt: return "Sleep debt"
        case .heartRate: return "Heart rate"
        case .spo2: return "Blood oxygen"
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .temperature: return "Temperature"
        case .exercise: return "Exercise"
        }
    }

    /// The name mid-sentence: lowercase, except an acronym.
    var inSentence: String { self == .hrv ? "HRV" : title.lowercased() }

    var symbol: String {
        switch self {
        case .battery: return "bolt.fill"
        case .steps: return "figure.walk"
        case .sleep: return "moon.fill"
        case .sleepDebt: return "moon.zzz.fill"
        case .heartRate: return RingMeasurementType.heartRate.icon
        case .spo2: return RingMeasurementType.spo2.icon
        case .hrv: return RingMeasurementType.hrv.icon
        case .stress: return RingMeasurementType.stress.icon
        case .temperature: return RingMeasurementType.temperature.icon
        case .exercise: return "figure.run"
        }
    }

    var tint: Color {
        switch self {
        case .battery, .steps, .exercise: return JcTheme.accent
        case .sleep: return JcTheme.accentAlt
        case .sleepDebt: return JcTheme.amber
        case .heartRate: return RingMeasurementType.heartRate.tint
        case .spo2: return RingMeasurementType.spo2.tint
        case .hrv: return RingMeasurementType.hrv.tint
        case .stress: return RingMeasurementType.stress.tint
        case .temperature: return RingMeasurementType.temperature.tint
        }
    }

    var style: Style {
        switch self {
        case .battery, .heartRate, .spo2: return .range
        case .steps, .exercise: return .bars
        case .sleep: return .stacked
        case .sleepDebt, .stress: return .bandBars
        case .hrv, .temperature: return .line
        }
    }
}

/// The spans a history screen switches between.
enum HealthRange: String, CaseIterable, Identifiable {
    case day = "D", week = "W", month = "M", halfYear = "6M", year = "Y"
    var id: String { rawValue }

    /// What one bar stands for.
    var unit: Calendar.Component {
        switch self {
        case .day, .week, .month: return .day
        case .halfYear: return .weekOfYear
        case .year: return .month
        }
    }
}
