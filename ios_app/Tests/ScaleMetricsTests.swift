import Foundation

@main
enum ScaleMetricsTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        var profile = ScaleUserProfile()
        profile.heightCm = 175
        let noImpedance = ScaleMetricsCalculator.metrics(weightKg: 70, impedanceOhms: nil, profile: profile)
        expect(abs((noImpedance[.bmi] ?? 0) - 22.857) < 0.01, "BMI must use metric height")
        expect(noImpedance[.bodyFat] == nil, "body composition needs impedance")

        let measured = ScaleMetricsCalculator.metrics(weightKg: 70, impedanceOhms: 500, profile: profile)
        expect(measured[.bodyFat] != nil, "impedance enables body fat estimate")
        expect(measured[.bmr] != nil, "profile enables BMR estimate")
    }
}
