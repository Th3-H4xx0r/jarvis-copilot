import XCTest
@testable import JarvisCopilot

/// Heart rate cut into sets and rests, and the calories and effort it adds up to.
final class SessionVitalsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Bench: set 1 ticked at 1:00, rest to 3:00; set 2 ticked at 4:00; the workout ends at 6:00.
    private func log() -> StrengthLog {
        StrengthLog(name: "Push", started: t0, exercises: [
            LoggedExercise(exerciseID: "Bench", name: "Bench", kind: .weightReps, sets: [
                LoggedSet(kg: 100, reps: 5, done: at(1), restEnd: at(3)),
                LoggedSet(kg: 100, reps: 5, done: at(4)),
                LoggedSet(kg: 100, reps: 5)])])
    }

    /// 100 bpm, 140 inside the sets (0:00–1:00 and 3:00–4:00), every second.
    private func samples() -> [HeartSample] {
        var out: [HeartSample] = []
        for second in 0...360 {
            let inSet = second <= 60 || (second >= 180 && second <= 240)
            out.append(HeartSample(at: t0.addingTimeInterval(Double(second)), bpm: inSet ? 140 : 100))
        }
        return out
    }

    func testSetsAndRestsAreCutFromTheTicks() {
        let workout = log()
        let w = SessionVitals.windows(workout, end: at(6))
        let sets = workout.exercises[0].sets
        XCTAssertEqual(w[sets[0].id]?.set, DateInterval(start: t0, end: at(1)))
        XCTAssertEqual(w[sets[0].id]?.rest, DateInterval(start: at(1), end: at(3)))
        XCTAssertEqual(w[sets[1].id]?.set, DateInterval(start: at(3), end: at(4)))
        XCTAssertNil(w[sets[1].id]?.rest)
        XCTAssertNil(w[sets[2].id], "an undone set has no window")
    }

    func testAnnotatingFillsEachSetAndTheTotals() throws {
        let out = SessionVitals.annotate(log(), samples: samples(), end: at(6))
        let first = out.exercises[0].sets[0], second = out.exercises[0].sets[1]
        XCTAssertEqual(first.hrAvg, 140)
        XCTAssertEqual(first.hrMax, 140)
        XCTAssertEqual(first.hrDrop, 40)
        XCTAssertEqual(second.start, at(3))
        XCTAssertEqual(try XCTUnwrap(first.e1rm), 112.5, accuracy: 0.05)
        XCTAssertEqual(out.volumeKg, 1000)
        XCTAssertEqual(out.sets, 2)
        XCTAssertEqual(out.activeSeconds, 120)
        XCTAssertEqual(out.restSeconds, 240)
    }

    private let lifter = VitalsProfile(age: 30, female: false, weightKg: 80, heightCm: 180, restingHR: 60)

    func testCaloriesFromHeartRateLessRestingBurn() {
        let steady = (0..<3600).map { HeartSample(at: t0.addingTimeInterval(Double($0)), bpm: 130) }
        let out = SessionVitals.activeCalories(samples: steady, start: t0, end: at(60), profile: lifter, ringKcal: 300)
        // Keytel for a man at 130 bpm, 80 kg, 30 years: kcal a minute.
        let heart: Double = 0.6309 * 130
        let body: Double = 0.1988 * 80 + 0.2017 * 30
        let keytel: Double = (heart + body - 55.0969) / 4.184
        // Mifflin–St Jeor for 80 kg, 180 cm, 30 years, a minute of it.
        let bmr: Double = 10 * 80 + 6.25 * 180 - 5 * 30 + 5
        let expected: Double = (keytel - bmr / 1440) * 60
        XCTAssertEqual(out.source, "heart_rate")
        XCTAssertEqual(out.kcal, expected, accuracy: expected * 0.01)
    }

    func testCaloriesFallBackToTheRingThenAnEstimate() {
        let sparse = (0..<1080).map { HeartSample(at: t0.addingTimeInterval(Double($0)), bpm: 130) }  // 30 % of an hour
        XCTAssertEqual(SessionVitals.activeCalories(samples: sparse, start: t0, end: at(60), profile: lifter, ringKcal: 300).source, "ring")
        let guess = SessionVitals.activeCalories(samples: [], start: t0, end: at(60), profile: lifter, ringKcal: nil)
        XCTAssertEqual(guess.source, "estimate")
        XCTAssertEqual(guess.kcal, 320, accuracy: 0.01)
    }

    func testEffortFromTrimp() {
        // Halfway into the reserve (60 → 190) for 30 minutes: 30 · 0.5 · 0.64 · e^0.96 ≈ 25.
        let half = (0..<1800).map { HeartSample(at: t0.addingTimeInterval(Double($0)), bpm: 125) }
        let trimp = SessionVitals.trimp(samples: half, profile: lifter)
        XCTAssertEqual(trimp, 30 * 0.5 * 0.64 * exp(0.96), accuracy: 0.3)
        XCTAssertEqual(SessionVitals.effort(trimp: trimp), 3)
        XCTAssertEqual(SessionVitals.effort(trimp: 0), 1)
        XCTAssertEqual(SessionVitals.effort(trimp: 250), 10)
    }

    func testTheFiveSecondSeriesLeavesGapsAtZero() {
        let series = SessionVitals.series5s(samples: [HeartSample(at: t0, bpm: 100), HeartSample(at: t0.addingTimeInterval(4), bpm: 110),
                                                      HeartSample(at: t0.addingTimeInterval(12), bpm: 120)],
                                            start: t0, end: t0.addingTimeInterval(20))
        XCTAssertEqual(series, [105, 0, 120, 0])
    }

    func testProfileFromTheRing() {
        let ring = RingProfile(use24Hour: true, metric: true, sex: 1, age: 41, heightCm: 165, weightKg: 0, systolic: 0,
                               diastolic: 0, heartRateWarning: 0, open: 0)
        let p = VitalsProfile(ring: ring, restingHR: nil)
        XCTAssertTrue(p.female)
        XCTAssertEqual(p.age, 41)
        XCTAssertNil(p.weightKg, "zero is not a weight")
        XCTAssertEqual(p.restingHR, 60)
    }
}
