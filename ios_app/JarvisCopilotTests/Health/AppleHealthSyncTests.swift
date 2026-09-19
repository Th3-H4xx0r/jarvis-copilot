import HealthKit
import XCTest
@testable import JarvisCopilot

/// What a ring day and a weigh-in become in Apple Health.
final class AppleHealthSyncTests: XCTestCase {
    private let key = "2026-09-17"
    private var midnight: Date { RingDates.date(forKey: key)! }
    private func at(_ minute: Int) -> Date { midnight.addingTimeInterval(Double(minute) * 60) }

    private func quantity(_ sample: AppleHealthSample) -> Double? {
        if case .quantity(_, _, let value) = sample.value { return value }
        return nil
    }

    func testHeartRateIsOneSamplePerReadingWithoutTheImplausible() {
        var day = RingDay(date: key)
        day.heartRate = RingSeries(intervalMinutes: 5, values: [60, 0, 250, 70])
        day.manualHeartRate = [RingTimedValue(minute: 12, value: 80)]
        let samples = AppleHealthPlan.samples(.heartRate, day: day)
        XCTAssertEqual(samples.map(\.start), [at(0), at(12), at(15)])
        XCTAssertEqual(samples.compactMap(quantity), [60, 80, 70])
        XCTAssertEqual(samples.first?.syncID, "jarvis-hr-20260917-0")
        XCTAssertEqual(samples.first?.value, .quantity(.heartRate, unit: "count/min", value: 60))
    }

    func testStepsDistanceAndEnergyArePerQuarterHourSkippingEmptySlots() {
        var day = RingDay(date: key)
        day.stepSlots = [RingStepSlot(slot: 4, steps: 500, calories: 3000, distanceMeters: 400),
                         RingStepSlot(slot: 5, steps: 0, calories: 0, distanceMeters: 0)]
        let steps = AppleHealthPlan.samples(.steps, day: day)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].start, at(60))
        XCTAssertEqual(steps[0].end, at(75))
        XCTAssertEqual(steps.compactMap(quantity), [500])
        // The ring counts small calories: 3000 is 3 kcal.
        XCTAssertEqual(AppleHealthPlan.samples(.activeEnergy, day: day).compactMap(quantity), [3])
        XCTAssertEqual(AppleHealthPlan.samples(.distance, day: day).compactMap(quantity), [400])
    }

    func testAWorkoutZeroesTheRingsEnergyAndDistanceButKeepsItsSteps() {
        var day = RingDay(date: key)
        day.stepSlots = [RingStepSlot(slot: 4, steps: 500, calories: 3000, distanceMeters: 400),
                         RingStepSlot(slot: 8, steps: 100, calories: 1000, distanceMeters: 80)]
        let run = [DateInterval(start: at(55), end: at(70))]
        let energy = AppleHealthPlan.samples(.activeEnergy, day: day, busy: run)
        XCTAssertEqual(energy.compactMap(quantity), [0, 1])
        XCTAssertEqual(energy[0].syncID, "jarvis-activeEnergy-20260917-4", "the same sample, replaced with zero")
        XCTAssertEqual(AppleHealthPlan.samples(.distance, day: day, busy: run).compactMap(quantity), [0, 80])
        XCTAssertEqual(AppleHealthPlan.samples(.steps, day: day, busy: run).compactMap(quantity), [500, 100])
    }

    func testSleepIsTheNightInBedWithItsStagesEndToEnd() {
        var day = RingDay(date: key)
        let start = at(-60)
        day.sleep = [RingSleepSession(start: start, end: start.addingTimeInterval(115 * 60), reportedStartMinute: 1380,
                                      stages: [RingSleepStage(stage: RingSleepStage.light, minutes: 60),
                                               RingSleepStage(stage: RingSleepStage.deep, minutes: 30),
                                               RingSleepStage(stage: RingSleepStage.rem, minutes: 20),
                                               RingSleepStage(stage: RingSleepStage.awake, minutes: 5)])]
        let samples = AppleHealthPlan.samples(.sleep, day: day)
        XCTAssertEqual(samples.map(\.value), [.sleep(.inBed), .sleep(.asleepCore), .sleep(.asleepDeep), .sleep(.asleepREM),
                                              .sleep(.awake)])
        XCTAssertEqual(samples[1].start, start)
        XCTAssertEqual(samples[2].start, samples[1].end)
        XCTAssertEqual(samples[4].end, start.addingTimeInterval(115 * 60))
        XCTAssertEqual(Set(samples.map(\.syncID)).count, samples.count)
    }

    func testRestingHeartRateIsTheMeanOfTheNightsThreeLowest() {
        var day = RingDay(date: key)
        day.sleep = [RingSleepSession(start: at(0), end: at(420), reportedStartMinute: 0,
                                      stages: [RingSleepStage(stage: RingSleepStage.light, minutes: 420)])]
        // Half-hourly: 52, 50, 54 and 49 at night; a 40 in the afternoon doesn't count.
        var values = [Double](repeating: 0, count: 48)
        values[2] = 52; values[4] = 50; values[6] = 54; values[8] = 49; values[10] = 65; values[30] = 40
        day.heartRate = RingSeries(intervalMinutes: 30, values: values)
        let samples = AppleHealthPlan.samples(.restingHeartRate, day: day)
        XCTAssertEqual(samples.compactMap(quantity), [50])
        XCTAssertEqual(samples.first?.start, at(420))
        XCTAssertEqual(samples.first?.syncID, "jarvis-rhr-20260917")
    }

    func testBloodOxygenIsTheHoursMidpointAsAFraction() {
        var day = RingDay(date: key)
        day.spo2 = RingMinMax(min: [95, 0, 96], max: [99, 0, 98])
        day.manualSpO2 = [RingTimedValue(minute: 600, value: 97)]
        let samples = AppleHealthPlan.samples(.bloodOxygen, day: day)
        XCTAssertEqual(samples.compactMap(quantity), [0.97, 0.97, 0.97])
        XCTAssertEqual(samples.map(\.start), [at(0), at(120), at(600)])
    }

    func testAWeighInIsWeightBodyFatBMIAndLeanMass() {
        let reading = ScaleReading(date: at(480), profileID: nil, model: "ESF-551", deviceID: "x", weightKg: 80,
                                   impedance: 500, metrics: [.weight: 80, .bmi: 24.7, .bodyFat: 18, .fatFreeWeight: 65.6],
                                   scaleUnit: .kilograms)
        let samples = AppleHealthPlan.body(reading)
        XCTAssertEqual(samples.map(\.value), [.quantity(.bodyMass, unit: "kg", value: 80),
                                              .quantity(.bodyFatPercentage, unit: "%", value: 0.18),
                                              .quantity(.bodyMassIndex, unit: "count", value: 24.7),
                                              .quantity(.leanBodyMass, unit: "kg", value: 65.6)])
        let bare = ScaleReading(date: at(480), profileID: nil, model: "ESF-551", deviceID: "x", weightKg: 80,
                                impedance: nil, metrics: [.weight: 80], scaleUnit: .kilograms)
        XCTAssertEqual(AppleHealthPlan.body(bare).count, 1)
    }

    func testEveryUnitParsesInHealthKit() {
        for unit in ["count/min", "ms", "%", "count", "m", "kcal", "kg"] {
            XCTAssertNoThrow(HKUnit(from: unit))
        }
        XCTAssertTrue(HKQuantityType(.heartRate).is(compatibleWith: HKUnit(from: "count/min")))
        XCTAssertTrue(HKQuantityType(.oxygenSaturation).is(compatibleWith: HKUnit(from: "%")))
        XCTAssertTrue(HKQuantityType(.bodyMassIndex).is(compatibleWith: HKUnit(from: "count")))
    }

    func testTheFingerprintChangesOnlyWithTheData() {
        var day = RingDay(date: key)
        day.heartRate = RingSeries(intervalMinutes: 5, values: [60, 62])
        let first = AppleHealthPlan.fingerprint(AppleHealthPlan.samples(.heartRate, day: day))
        XCTAssertEqual(first, AppleHealthPlan.fingerprint(AppleHealthPlan.samples(.heartRate, day: day)))
        day.heartRate?.values.append(64)
        XCTAssertNotEqual(first, AppleHealthPlan.fingerprint(AppleHealthPlan.samples(.heartRate, day: day)))
    }

    func testEveryKindIsOnUntilSwitchedOff() {
        XCTAssertEqual(AppleHealthKind.allCases.count, 10)
        XCTAssertTrue(AppleHealthKind.allCases.allSatisfy { !$0.sampleTypes.isEmpty })
        XCTAssertFalse(AppleHealthKind.fromRingDays.contains(.workouts))
        XCTAssertFalse(AppleHealthKind.fromRingDays.contains(.body))
    }
}
