import XCTest
@testable import JarvisCopilot

/// Lists and grouped settings in a device action's form: what used to fail with
/// "needs a structured input" (ring metrics, alarm days, do-not-disturb, light timers).
final class SkillArgsFormStructuredTests: XCTestCase {

    private let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "metrics": ["type": "array", "items": ["type": "string", "enum": ["heart_rate", "spo2", "steps"]]],
            "days": ["type": "array", "items": ["type": "integer"]],
            "dnd": ["type": "object", "properties": [
                "enabled": ["type": "boolean"],
                "start": ["type": "string"],
                "minutes": ["type": "integer", "maximum": 600],
            ]],
            "label": ["type": "string"],
        ],
    ]

    private func field(_ key: String) -> SkillArgField? {
        SkillArgsForm.fields(from: schema).first { $0.key == key }
    }

    func testListsAndObjectsGetTheirOwnKinds() {
        XCTAssertEqual(field("metrics")?.kind, .list)
        XCTAssertEqual(field("metrics")?.options, ["heart_rate", "spo2", "steps"])
        XCTAssertEqual(field("days")?.kind, .list)
        XCTAssertEqual(field("days")?.itemType, "integer")
        XCTAssertEqual(field("dnd")?.kind, .object)
        XCTAssertEqual(field("dnd")?.subfields.map(\.key), ["enabled", "minutes", "start"])
    }

    func testAPickedListBecomesAnArray() throws {
        let args = try SkillArgsForm.validatedArguments(["metrics": "heart_rate, spo2"], schema: schema)
        XCTAssertEqual(args["metrics"] as? [String], ["heart_rate", "spo2"])
    }

    func testAnUnknownListItemIsRefused() {
        XCTAssertThrowsError(try SkillArgsForm.validatedArguments(["metrics": "heart_rate,mood"], schema: schema))
    }

    func testANumberListIsTyped() throws {
        let args = try SkillArgsForm.validatedArguments(["days": "1,3, 5"], schema: schema)
        XCTAssertEqual(args["days"] as? [Int], [1, 3, 5])
        XCTAssertThrowsError(try SkillArgsForm.validatedArguments(["days": "1,two"], schema: schema))
    }

    func testAGroupedSettingIsAnObjectWithTypedValues() throws {
        let dnd = SkillArgsForm.objectText(["enabled": "true", "start": "22:00", "minutes": "90"])
        let args = try SkillArgsForm.validatedArguments(["dnd": dnd], schema: schema)
        let object = try XCTUnwrap(args["dnd"] as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["start"] as? String, "22:00")
        XCTAssertEqual(object["minutes"] as? Int, 90)
    }

    func testAGroupedSettingIsCheckedLikeAnyField() {
        let dnd = SkillArgsForm.objectText(["minutes": "900"])
        XCTAssertThrowsError(try SkillArgsForm.validatedArguments(["dnd": dnd], schema: schema))
    }

    func testObjectTextRoundTrips() {
        let values = ["enabled": "true", "start": "22:00"]
        XCTAssertEqual(SkillArgsForm.objectValues(SkillArgsForm.objectText(values)), values)
        XCTAssertEqual(SkillArgsForm.objectValues(""), [:])
    }

    func testDefaultsFillTheFormInItsOwnFormat() {
        XCTAssertEqual(SkillArgsForm.initialText(["heart_rate", "spo2"], field: field("metrics")!), "heart_rate,spo2")
        XCTAssertEqual(SkillArgsForm.initialText(["enabled": true], field: field("dnd")!),
                       SkillArgsForm.objectText(["enabled": "true"]))
        XCTAssertEqual(SkillArgsForm.initialText("x", field: field("label")!), "x")
    }

    func testPlainFieldsBehaveAsBefore() throws {
        let args = try SkillArgsForm.validatedArguments(["label": "hello"], schema: schema)
        XCTAssertEqual(args["label"] as? String, "hello")
        XCTAssertEqual(args.count, 1, "blank fields are left out")
    }
}
