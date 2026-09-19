import XCTest
@testable import JarvisCopilot

/// The bundled exercise library: loaded, mapped onto Strong's kinds, searchable.
@MainActor
final class ExerciseLibraryTests: XCTestCase {
    func testTheBundledLibraryLoads() throws {
        let lib = ExerciseLibrary()
        XCTAssertGreaterThan(lib.builtIn.count, 800)
        let bench = try XCTUnwrap(lib.builtIn.first { $0.name == "Barbell Bench Press - Medium Grip" })
        XCTAssertEqual(bench.equipment, .barbell)
        XCTAssertEqual(bench.kind, .weightReps)
        XCTAssertEqual(bench.primaryMuscles, ["chest"])
        XCTAssertFalse(bench.instructions.isEmpty)
        XCTAssertEqual(bench.images.count, 2)
        XCTAssertEqual(lib.builtIn.first { $0.name == "Plank" }?.kind, .duration)
        XCTAssertEqual(lib.builtIn.first { $0.name == "Pullups" }?.kind, .repsOnly)
    }

    func testKindsFollowCategoryAndEquipment() {
        XCTAssertEqual(ExerciseLibrary.kind(category: "strength", equipment: .bodyweight), .repsOnly)
        XCTAssertEqual(ExerciseLibrary.kind(category: "stretching", equipment: .other), .duration)
        XCTAssertEqual(ExerciseLibrary.kind(category: "cardio", equipment: .machine), .distanceDuration)
        XCTAssertEqual(ExerciseLibrary.kind(category: "powerlifting", equipment: .barbell), .weightReps)
        XCTAssertEqual(ExerciseLibrary.equipment("e-z curl bar"), .ezBar)
        XCTAssertEqual(ExerciseLibrary.equipment(nil), .other)
    }

    func testSearchMatchesEveryWordAndPutsNamePrefixesFirst() {
        let lib = ExerciseLibrary()
        let hits = ExerciseLibrary.search(lib.builtIn, text: "barbell bench", muscle: nil, equipment: .barbell)
        XCTAssertEqual(hits.first?.name.hasPrefix("Barbell Bench"), true)
        XCTAssertTrue(hits.allSatisfy { $0.equipment == .barbell })
        let chest = ExerciseLibrary.search(lib.builtIn, text: "", muscle: "chest", equipment: nil)
        XCTAssertTrue(chest.allSatisfy { $0.primaryMuscles.contains("chest") || $0.secondaryMuscles.contains("chest") })
        XCTAssertTrue(ExerciseLibrary.search(lib.builtIn, text: "zzzqqq", muscle: nil, equipment: nil).isEmpty)
    }

    func testCustomExercisesAndKindOverridesMerge() {
        let lib = ExerciseLibrary()
        let mine = Exercise(id: "custom-zercher", name: "Zercher Carry", equipment: .barbell, kind: .distanceDuration,
                            primaryMuscles: ["quadriceps"], custom: true)
        let all = lib.all(custom: [mine], settings: ["Plank": ExerciseSettings(kind: .weightedBodyweight)])
        XCTAssertTrue(all.contains(mine))
        XCTAssertEqual(all.first { $0.id == "Plank" }?.kind, .weightedBodyweight)
        XCTAssertEqual(lib.exercise("custom-zercher", custom: [mine], settings: [:])?.name, "Zercher Carry")
        XCTAssertNil(lib.exercise("nope", custom: [], settings: [:]))
    }
}
