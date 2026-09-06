import Foundation

/// Local body-composition estimates. They are informational only: impedance scales
/// cannot diagnose health conditions and should not be used for clinical decisions.
enum ScaleMetricsCalculator {
    static func metrics(weightKg: Double, impedanceOhms: Double?, profile: ScaleUserProfile)
    -> [BodyMetric: Double] {
        guard weightKg > 0, profile.heightCm > 0 else { return [:] }
        let heightM = profile.heightCm / 100
        let bmi = weightKg / (heightM * heightM)
        var result: [BodyMetric: Double] = [.weight: weightKg, .bmi: bmi]
        guard let impedanceOhms, impedanceOhms > 0 else { return result }

        let sexOffset = profile.sex == .female ? -5.4 : -16.2
        let athleteOffset = profile.athleteMode ? -2.0 : 0.0
        let impedanceAdjustment = (500 - impedanceOhms) * 0.015
        let bodyFat = clamp(1.2 * bmi + 0.23 * Double(profile.age) + sexOffset
                            + athleteOffset + impedanceAdjustment, 2, 60)
        let fatFree = weightKg * (1 - bodyFat / 100)
        let muscle = fatFree * 0.80
        let bone = weightKg * (profile.sex == .female ? 0.034 : 0.040)
        let water = clamp((fatFree * 0.73 / weightKg) * 100, 35, 75)
        let bmr = profile.sex == .female
            ? 10 * weightKg + 6.25 * profile.heightCm - 5 * Double(profile.age) - 161
            : 10 * weightKg + 6.25 * profile.heightCm - 5 * Double(profile.age) + 5

        result[.bodyFat] = bodyFat
        result[.fatFreeWeight] = fatFree
        result[.subcutaneousFat] = bodyFat * 0.84
        result[.visceralFat] = clamp(round((bmi - 18) * 0.65 + Double(profile.age) * 0.08), 1, 30)
        result[.bodyWater] = water
        result[.muscleMass] = muscle
        result[.skeletalMuscle] = muscle / weightKg * 100
        result[.boneMass] = bone
        result[.protein] = clamp(fatFree / weightKg * 20, 8, 25)
        result[.bmr] = bmr
        result[.metabolicAge] = max(18, Double(profile.age) + (bmi - 22) * 0.8)
        return result
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
