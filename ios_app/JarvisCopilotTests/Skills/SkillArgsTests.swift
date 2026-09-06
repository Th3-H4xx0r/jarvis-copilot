import XCTest
@testable import JarvisCopilot

/// `SkillText.swift`: the loose-`[String: Any]` coercions every ported skill
/// leans on, and the regex wrapper the grammar files are written against.
///
/// These are the Dart semantics the port promised (`(value ?? '').toString()`,
/// `args[key] is num`), so a regression here silently changes what every skill
/// sees on the wire.
final class SkillArgsTests: XCTestCase {

    // MARK: text

    func testTextPrintsBooleansAsWords() {
        XCTAssertEqual(SkillArgs.text(true), "true")
        XCTAssertEqual(SkillArgs.text(false), "false")
        // Boxed the way JSONSerialization hands them over.
        XCTAssertEqual(SkillArgs.text(NSNumber(value: true)), "true")
    }

    func testTextPrintsNumbersWithoutASpuriousPointZero() {
        XCTAssertEqual(SkillArgs.text(5), "5")
        XCTAssertEqual(SkillArgs.text(5.5), "5.5")
    }

    func testTextTreatsNullAndAbsentAsEmpty() {
        XCTAssertEqual(SkillArgs.text(nil), "")
        XCTAssertEqual(SkillArgs.text(NSNull()), "")
        XCTAssertEqual(SkillArgs.string(["a": 1], "missing"), "")
    }

    // MARK: number / int / bool

    func testNumberRejectsStringsAndBooleans() {
        XCTAssertNil(SkillArgs.number(["v": "5"], "v"), "a numeric string is not a number")
        XCTAssertNil(SkillArgs.number(["v": true], "v"))
        XCTAssertNil(SkillArgs.number([:], "v"))
        XCTAssertEqual(SkillArgs.number(["v": 5], "v"), 5)
        XCTAssertEqual(SkillArgs.number(["v": 0.25], "v"), 0.25)
    }

    func testIntTruncatesAndInheritsTheSameRejections() {
        XCTAssertEqual(SkillArgs.int(["v": 5.9], "v"), 5)
        XCTAssertNil(SkillArgs.int(["v": "5"], "v"))
    }

    func testBoolOnlyAcceptsRealBooleans() {
        XCTAssertEqual(SkillArgs.bool(["v": true], "v"), true)
        XCTAssertEqual(SkillArgs.bool(["v": NSNumber(value: false)], "v"), false)
        XCTAssertNil(SkillArgs.bool(["v": 1], "v"))
        XCTAssertNil(SkillArgs.bool(["v": "true"], "v"))
    }

    // MARK: intList

    func testIntListMapsUnusableElementsToZero() {
        XCTAssertEqual(SkillArgs.intList(["p": [0, 500, "nope", true, 250]], "p"),
                       [0, 500, 0, 0, 250])
    }

    func testIntListIsNilWhenAbsentOrEmpty() {
        XCTAssertNil(SkillArgs.intList([:], "p"))
        XCTAssertNil(SkillArgs.intList(["p": [Any]()], "p"))
        XCTAssertNil(SkillArgs.intList(["p": "0,500"], "p"))
    }

    // MARK: titleCase

    func testTitleCaseCapitalisesEachWordAndLeavesTheRestAlone() {
        XCTAssertEqual(SkillArgs.titleCase("wells fargo"), "Wells Fargo")
        XCTAssertEqual(SkillArgs.titleCase("mcDonalds"), "McDonalds")
        XCTAssertEqual(SkillArgs.titleCase(""), "")
        XCTAssertEqual(SkillArgs.titleCase("  spotify  "), "Spotify")
    }

    // MARK: Rx

    func testRxMatchesAndExposesGroups() {
        let rx = Rx("set (\\w+) to (\\d+)")
        XCTAssertTrue(rx.isValid)
        let m = rx.firstMatch("Set volume to 40")
        XCTAssertEqual(m?.group(1), "volume")
        XCTAssertEqual(m?.group(2), "40")
        XCTAssertNil(m?.group(9), "an out-of-range group is nil, not a crash")
    }

    /// A pattern that doesn't compile used to `try!` and take the process down.
    /// It must degrade to a rule that never fires instead.
    func testAnInvalidPatternNeverMatchesInsteadOfCrashing() {
        let rx = Rx("([unclosed")
        XCTAssertFalse(rx.isValid)
        XCTAssertFalse(rx.hasMatch("[unclosed"))
        XCTAssertNil(rx.firstMatch("anything"))
        XCTAssertTrue(rx.allMatches("anything").isEmpty)
        XCTAssertEqual(rx.replacingFirst(in: "anything", with: "x"), "anything")
    }
}
