import XCTest
@testable import JarvisCopilot

/// Units, and the strength payload riding on a workout in the server's keys.
final class TrainingModelsTests: XCTestCase {
    func testUnitsConvert() {
        XCTAssertEqual(TrainingUnit.lb.show(100), 220.46, accuracy: 0.01)
        XCTAssertEqual(TrainingUnit.lb.kilograms(225), 102.058, accuracy: 0.001)
        XCTAssertEqual(TrainingUnit.kg.format(62.5), "62.5")
        XCTAssertEqual(TrainingUnit.kg.format(60), "60")
        XCTAssertEqual(TrainingUnit.lb.format(TrainingUnit.lb.kilograms(135)), "135")
        XCTAssertEqual(ExerciseKind.assistedBodyweight.weightHeading(.kg), "−kg")
    }

    private func workout() -> RingWorkout {
        var w = RingWorkout(sport: 88, sportName: "Push Day", start: Date(timeIntervalSince1970: 1_000_000),
                            end: Date(timeIntervalSince1970: 1_003_600), activeSeconds: 3600, steps: 0, distanceMeters: 0,
                            distanceSource: "ring", kilocalories: 250, heartRateAverage: 110, heartRateMax: 150,
                            heartRates: [0, 100], zoneSeconds: [0, 0, 0, 0, 0])
        w.strength = StrengthLog(name: "Push Day", templateID: "a1", started: w.start, exercises: [
            LoggedExercise(exerciseID: "Barbell_Bench_Press_-_Medium_Grip", name: "Bench", kind: .weightReps, superset: 1,
                           sets: [LoggedSet(tag: .warmup, kg: 20, reps: 10),
                                  LoggedSet(kg: 60, reps: 8, rpe: 8, done: w.start, restEnd: w.start, hrAvg: 120)])])
        w.effort = 6
        w.kcalSource = "heart_rate"
        return w
    }

    func testAStrengthWorkoutRoundTripsInTheServersKeys() throws {
        let w = workout()
        let json = String(data: try JSONEncoder().encode(w), encoding: .utf8)!
        for key in ["\"template_id\"", "\"exercise_id\"", "\"hr_avg\"", "\"rest_end\"", "\"kcal_source\"", "\"effort\"",
                    "\"volume_kg\"", "\"strength\""] {
            XCTAssertTrue(json.contains(key), key)
        }
        XCTAssertEqual(try JSONDecoder().decode(RingWorkout.self, from: Data(json.utf8)), w)
    }

    func testAnOlderWorkoutWithoutStrengthStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workout())) as? [String: Any])
        object.removeValue(forKey: "strength")
        object.removeValue(forKey: "effort")
        object.removeValue(forKey: "kcal_source")
        let decoded = try JSONDecoder().decode(RingWorkout.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.strength)
        XCTAssertFalse(decoded.isStrength)
    }

    func testASparseSetFromTheServerDecodes() throws {
        let set = try JSONDecoder().decode(LoggedSet.self, from: Data(#"{"kg": 40, "reps": 12}"#.utf8))
        XCTAssertEqual(set.tag, .working)
        XCTAssertEqual(set.kg, 40)
        XCTAssertEqual(set.records, [])
    }

    func testEmptyWorkoutsAreNamedForTheTimeOfDay() {
        var parts = DateComponents(year: 2026, month: 9, day: 19, hour: 7)
        XCTAssertEqual(StrengthLog.defaultName(at: Calendar.current.date(from: parts)!), "Morning Workout")
        parts.hour = 18
        XCTAssertEqual(StrengthLog.defaultName(at: Calendar.current.date(from: parts)!), "Evening Workout")
    }
}
