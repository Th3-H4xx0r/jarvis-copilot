import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/island_bindings_test.dart`, case for case.
final class IslandBindingsTests: XCTestCase {

    // MARK: evaluateCondition

    func testNilOrEmptyIsAlwaysTrue() {
        XCTAssertTrue(IslandBindings.evaluateCondition(nil, [:]))
        XCTAssertTrue(IslandBindings.evaluateCondition([:], [:]))
    }

    func testGTAndLTWithASourceOperand() {
        let condition: JSONObject = ["op": "gt", "a": ["src": "battery.level"], "b": 20]
        XCTAssertTrue(IslandBindings.evaluateCondition(condition, ["battery.level": 50]))
        XCTAssertFalse(IslandBindings.evaluateCondition(condition, ["battery.level": 10]))

        let lt: JSONObject = ["op": "lt", "a": ["src": "battery.level"], "b": 20]
        XCTAssertTrue(IslandBindings.evaluateCondition(lt, ["battery.level": 10]))
        XCTAssertFalse(IslandBindings.evaluateCondition(lt, ["battery.level": 50]))
    }

    func testMissingOperandFailsSafe() {
        let condition: JSONObject = ["op": "gt", "a": ["src": "battery.level"], "b": 20]
        XCTAssertFalse(IslandBindings.evaluateCondition(condition, [:]))
    }

    func testEQAndNENumericAndString() {
        XCTAssertTrue(IslandBindings.evaluateCondition(
            ["op": "eq", "a": ["$": "state"], "b": "running"], ["state": "running"]))
        XCTAssertTrue(IslandBindings.evaluateCondition(
            ["op": "ne", "a": ["$": "n"], "b": 3], ["n": 4]))
    }

    func testAndOrNot() {
        let and: JSONObject = ["op": "and", "items": [
            ["op": "exists", "a": ["src": "x"]],
            ["op": "gt", "a": ["src": "x"], "b": 0],
        ]]
        XCTAssertTrue(IslandBindings.evaluateCondition(and, ["x": 5]))
        XCTAssertFalse(IslandBindings.evaluateCondition(and, ["x": -1]))

        let or: JSONObject = ["op": "or", "items": [
            ["op": "eq", "a": ["src": "a"], "b": 1],
            ["op": "eq", "a": ["src": "b"], "b": 1],
        ]]
        XCTAssertTrue(IslandBindings.evaluateCondition(or, ["a": 0, "b": 1]))
        XCTAssertFalse(IslandBindings.evaluateCondition(or, ["a": 0, "b": 0]))

        let not: JSONObject = ["op": "not", "item": ["op": "exists", "a": ["src": "x"]]]
        XCTAssertTrue(IslandBindings.evaluateCondition(not, [:]))
        XCTAssertFalse(IslandBindings.evaluateCondition(not, ["x": 1]))
    }

    func testBetween() {
        let condition: JSONObject = ["op": "between", "a": ["src": "p"], "lo": 10, "hi": 20]
        XCTAssertTrue(IslandBindings.evaluateCondition(condition, ["p": 15]))
        XCTAssertFalse(IslandBindings.evaluateCondition(condition, ["p": 25]))
        XCTAssertFalse(IslandBindings.evaluateCondition(condition, [:]))
    }

    func testUnknownOpIsFalse() {
        XCTAssertFalse(IslandBindings.evaluateCondition(["op": "wat"], [:]))
    }

    func testStringNumbersCompareNumerically() {
        XCTAssertTrue(IslandBindings.evaluateCondition(
            ["op": "eq", "a": ["src": "n"], "b": 3], ["n": "3"]))
        XCTAssertTrue(IslandBindings.evaluateCondition(
            ["op": "gt", "a": ["src": "n"], "b": "2"], ["n": 3]))
    }

    // MARK: Source resolution

    func testCollectSourceKeysFindsNestedSrcRefs() {
        let tree: JSONObject = [
            "type": "vstack",
            "children": [
                ["type": "text", "value": ["src": "battery.level"]],
                [
                    "type": "list",
                    "data": ["src": "coding.fleet"],
                    "row": ["type": "dot", "color": ["$": "state"]],
                ],
            ],
        ]
        let keys = IslandBindings.collectSourceKeys(tree)
        XCTAssertTrue(keys.isSuperset(of: ["battery.level", "coding.fleet"]))
    }

    func testResolveDataOverlaysServerDataWithKnownSources() {
        let design = IslandDesign(
            id: "d", name: "d", icon: "", version: 1,
            raw: [
                "type": "hstack",
                "children": [
                    ["type": "text", "value": ["src": "battery.level"]],
                    ["type": "text", "value": ["$": "deploy"]],
                ],
            ])
        let out = IslandBindings.resolveData(
            design,
            sources: ["battery.level": 42, "time.now": 999],
            serverData: ["deploy": "ok"])

        XCTAssertEqual(out["deploy"] as? String, "ok")           // from server data
        XCTAssertEqual(MoreJSON.int(out["battery.level"]), 42)   // referenced source
        XCTAssertNil(out["time.now"])                            // not referenced → omitted
    }

    func testCollectSourceKeysIgnoresEmptyAndNonStringSrc() {
        XCTAssertTrue(IslandBindings.collectSourceKeys(["src": ""] as JSONObject).isEmpty)
        XCTAssertTrue(IslandBindings.collectSourceKeys(["src": 42] as JSONObject).isEmpty)
        XCTAssertTrue(IslandBindings.collectSourceKeys(nil).isEmpty)
        XCTAssertTrue(IslandBindings.collectSourceKeys("plain").isEmpty)
    }
}
