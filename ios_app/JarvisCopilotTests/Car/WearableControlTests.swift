import XCTest
@testable import JarvisCopilot

@MainActor
final class WearableControlTests: XCTestCase {
    private func control(_ kind: WearableControl.Kind) -> WearableControl {
        WearableControl(id: "lights.x", title: "X", symbol: "power", kind: kind) { _ in }
    }

    func testToggleTakesBooleansAndOnOffWords() throws {
        let c = control(.toggle(isOn: false))
        XCTAssertEqual(try c.value(fromJSON: true), .toggle(true))
        XCTAssertEqual(try c.value(fromJSON: "off"), .toggle(false))
        XCTAssertEqual(try c.value(fromJSON: "ON"), .toggle(true))
        XCTAssertThrowsError(try c.value(fromJSON: "maybe"))
        XCTAssertThrowsError(try c.value(fromJSON: nil))
    }

    func testLevelClampsAndSnapsToItsStep() throws {
        let c = control(.level(value: 0, range: 0...100, step: 5, unit: "%"))
        XCTAssertEqual(try c.value(fromJSON: 62), .level(60))
        XCTAssertEqual(try c.value(fromJSON: 63), .level(65))
        XCTAssertEqual(try c.value(fromJSON: 150), .level(100))
        XCTAssertEqual(try c.value(fromJSON: -3), .level(0))
        XCTAssertEqual(try c.value(fromJSON: "40"), .level(40))
        XCTAssertThrowsError(try c.value(fromJSON: "bright"))
        XCTAssertThrowsError(try c.value(fromJSON: Double.nan))
    }

    func testFractionalStepsDoNotDrift() {
        XCTAssertEqual(WearableControl.snap(0.29, range: 0...1, step: 0.1), 0.3)
        XCTAssertEqual(WearableControl.snap(7, range: 0...10, step: 0), 7, "no step: clamp only")
    }

    func testChoiceTakesAnOptionIdOrTitle() throws {
        let c = control(.choice(selected: "calm", options: [.init(id: "calm", title: "Calm"), .init(id: "party", title: "Party")]))
        XCTAssertEqual(try c.value(fromJSON: "party"), .choice("party"))
        XCTAssertEqual(try c.value(fromJSON: "PARTY"), .choice("party"))
        XCTAssertThrowsError(try c.value(fromJSON: "disco")) { error in
            XCTAssertTrue(error.localizedDescription.contains("calm, party"), error.localizedDescription)
        }
    }

    func testButtonIgnoresItsValue() throws {
        XCTAssertEqual(try control(.button).value(fromJSON: nil), .press)
        XCTAssertEqual(try control(.button).value(fromJSON: "anything"), .press)
    }

    func testStateJSONSaysWhatItAccepts() {
        let level = control(.level(value: 60, range: 0...100, step: 5, unit: "%")).stateJSON
        XCTAssertEqual(level["kind"] as? String, "level")
        XCTAssertEqual(level["value"] as? Double, 60)
        XCTAssertEqual(level["max"] as? Double, 100)
        XCTAssertEqual(level["unit"] as? String, "%")
        let choice = control(.choice(selected: "calm", options: [.init(id: "calm", title: "Calm")])).stateJSON
        XCTAssertEqual((choice["options"] as? [[String: String]])?.first?["id"], "calm")
        XCTAssertEqual(control(.toggle(isOn: true)).valueText, "On")
        XCTAssertEqual(control(.level(value: 60, range: 0...100, step: 5, unit: "%")).valueText, "60 %")
        XCTAssertNil(control(.button).valueText)
    }
}
