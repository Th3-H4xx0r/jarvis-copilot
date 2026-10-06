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
    /// From the scales linked to Jarvis Health.
    case weight
    case bodyFat = "body_fat"
    // The band's spot readings (the server's `vitals`), kept in their canonical units.
    case bloodPressure = "blood_pressure"
    case bloodGlucose = "blood_glucose"
    case uricAcid = "uric_acid"
    case cholesterol, triglycerides, hdl, ldl
    case bmi
    case muscleMass = "muscle_mass"
    case skeletalMuscle = "skeletal_muscle"
    case bodyWater = "body_water"
    case boneMass = "bone_mass"
    case protein, bmr
    case ecg
    case ecgHrv = "ecg_hrv"
    case respiratoryRate = "respiratory_rate"
    case ecgQtc = "ecg_qtc"

    var id: String { rawValue }

    /// A spot reading the band takes, rather than a day's tracking.
    var isVital: Bool { self != .bodyFat && HealthMetricGroup.allCases.contains { $0.metrics.contains(self) } }

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
        case .weight: return "Weight"
        case .bodyFat: return "Body fat"
        case .bloodPressure: return "Blood pressure"
        case .bloodGlucose: return "Blood glucose"
        case .uricAcid: return "Uric acid"
        case .cholesterol: return "Total cholesterol"
        case .triglycerides: return "Triglycerides"
        case .hdl: return "HDL"
        case .ldl: return "LDL"
        case .bmi: return "BMI"
        case .muscleMass: return "Muscle mass"
        case .skeletalMuscle: return "Skeletal muscle"
        case .bodyWater: return "Body water"
        case .boneMass: return "Bone mass"
        case .protein: return "Protein"
        case .bmr: return "Basal metabolism"
        case .ecg: return "ECG heart rate"
        case .ecgHrv: return "ECG HRV"
        case .respiratoryRate: return "Breathing rate"
        case .ecgQtc: return "QTc"
        }
    }

    /// The short name on a group's switch.
    var shortTitle: String {
        switch self {
        case .cholesterol: return "Cholesterol"
        case .triglycerides: return "TG"
        case .muscleMass: return "Muscle"
        case .skeletalMuscle: return "Skeletal"
        case .bodyWater: return "Water"
        case .boneMass: return "Bone"
        case .bmr: return "BMR"
        case .ecg: return "Heart rate"
        case .ecgHrv: return "HRV"
        case .respiratoryRate: return "Breathing"
        default: return title
        }
    }

    /// The name mid-sentence: lowercase, except an acronym.
    var inSentence: String {
        [.hrv, .hdl, .ldl, .bmi, .ecgHrv, .ecgQtc].contains(self) ? title : title.lowercased()
    }

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
        case .weight: return "scalemass.fill"
        case .bodyFat: return "percent"
        case .bloodPressure: return BandMeasure.bloodPressure.icon
        case .bloodGlucose: return BandMeasure.bloodGlucose.icon
        case .uricAcid, .cholesterol, .triglycerides, .hdl, .ldl: return BandMeasure.bloodComponent.icon
        case .bmi, .muscleMass, .skeletalMuscle, .bodyWater, .boneMass, .protein, .bmr:
            return BandMeasure.bodyComposition.icon
        case .ecg, .ecgHrv, .respiratoryRate, .ecgQtc: return BandMeasure.ecg.icon
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
        case .weight: return JcTheme.blue
        case .bodyFat: return JcTheme.success
        case .bloodPressure: return BandMeasure.bloodPressure.tint
        case .bloodGlucose: return BandMeasure.bloodGlucose.tint
        case .uricAcid, .cholesterol, .triglycerides, .hdl, .ldl: return BandMeasure.bloodComponent.tint
        case .bmi, .muscleMass, .skeletalMuscle, .bodyWater, .boneMass, .protein, .bmr:
            return BandMeasure.bodyComposition.tint
        case .ecg, .ecgHrv, .respiratoryRate, .ecgQtc: return BandMeasure.ecg.tint
        }
    }

    var style: Style {
        switch self {
        case .battery, .heartRate, .spo2: return .range
        case .steps, .exercise: return .bars
        case .sleep: return .stacked
        case .sleepDebt, .stress: return .bandBars
        case .hrv, .temperature, .weight, .bodyFat: return .line
        // Diastolic (the bucket's low) up to systolic (its value).
        case .bloodPressure: return .range
        default: return .line
        }
    }

    /// The ranges its history screen offers: a spot reading has no day view of its own.
    var ranges: [HealthRange] { isVital ? HealthRange.allCases.filter { $0 != .day } : HealthRange.allCases }
}

/// The band's readings, grouped as its pages switch between them (the official app's
/// "Uric acid | Lipid", body composition's parts, ECG's figures).
enum HealthMetricGroup: String, CaseIterable, Identifiable {
    case bloodPressure, bloodGlucose, bloodComponents, bodyComposition, ecg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bloodPressure: return "Blood pressure"
        case .bloodGlucose: return "Blood glucose"
        case .bloodComponents: return "Blood components"
        case .bodyComposition: return "Body composition"
        case .ecg: return "ECG"
        }
    }

    var metrics: [HealthMetric] {
        switch self {
        case .bloodPressure: return [.bloodPressure]
        case .bloodGlucose: return [.bloodGlucose]
        case .bloodComponents: return [.uricAcid, .cholesterol, .triglycerides, .hdl, .ldl]
        case .bodyComposition: return [.bmi, .bodyFat, .skeletalMuscle, .muscleMass, .bodyWater, .boneMass, .protein, .bmr]
        case .ecg: return [.ecg, .ecgHrv, .ecgQtc, .respiratoryRate]
        }
    }

    var symbol: String { metrics[0].symbol }
    var tint: Color { metrics[0].tint }
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
