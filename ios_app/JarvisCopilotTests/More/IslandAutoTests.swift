import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/island_auto_test.dart`, case for case.
final class IslandAutoTests: XCTestCase {

    private func entry(_ id: String, builtin: Bool = false, enabled: Bool = true,
                       priority: Int = 10, conditions: JSONObject? = nil,
                       schedule: JSONObject? = nil) -> IslandCatalogEntry {
        IslandCatalogEntry(id: id, name: id, icon: "", version: 1, builtin: builtin,
                           enabled: enabled, priority: priority,
                           conditions: conditions, schedule: schedule)
    }

    private func design(_ id: String) -> IslandDesign {
        IslandDesign(id: id, name: id, icon: "", version: 1, raw: ["id": id])
    }

    private func catalog(extra: [IslandCatalogEntry] = [],
                         designs: [IslandDesign] = [],
                         selection: IslandSelection = .auto) -> IslandCatalog {
        IslandCatalog(designs: designs,
                      entries: [entry("voice", builtin: true, priority: 100),
                                entry("coding", builtin: true, priority: 50)] + extra,
                      selection: selection,
                      data: [:])
    }

    /// A Friday at 14:00 local, matching the Dart fixture's `DateTime(2026,6,19,14,0)`.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 19
        components.hour = 14
        components.minute = 0
        return Calendar.current.date(from: components)!
    }()

    private func pick(_ catalog: IslandCatalog, voice: Bool = false, coding: Bool = false,
                      sources: JSONObject = [:]) -> IslandActive {
        IslandAuto.selectActiveDesign(catalog: catalog, voiceActive: voice,
                                      codingLive: coding, sources: sources, now: now)
    }

    func testTheFixtureDateIsAFriday() {
        XCTAssertEqual(IslandAuto.isoWeekday(now), 5)
    }

    func testLiveVoiceTurnAlwaysWins() {
        let cat = catalog(selection: IslandSelection(mode: "pinned", pinnedID: "coding"))
        XCTAssertEqual(pick(cat, voice: true, coding: true).kind, "voice")
    }

    func testPinnedCustomDesignShows() {
        let cat = catalog(extra: [entry("deploy")], designs: [design("deploy")],
                          selection: IslandSelection(mode: "pinned", pinnedID: "deploy"))
        let active = pick(cat)
        XCTAssertEqual(active.kind, "custom")
        XCTAssertEqual(active.id, "deploy")
        XCTAssertTrue(active.isCustom)
    }

    func testPinnedCodingShowsCoding() {
        let cat = catalog(selection: IslandSelection(mode: "pinned", pinnedID: "coding"))
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
    }

    func testPinnedToMissingDesignFallsThroughToAuto() {
        let cat = catalog(selection: IslandSelection(mode: "pinned", pinnedID: "ghost"))
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
        XCTAssertEqual(pick(cat).kind, "none")
    }

    func testAutoPicksCodingWhenSessionsLiveAndNoCustom() {
        XCTAssertEqual(pick(catalog(), coding: true).kind, "coding")
    }

    func testAutoPicksHigherPriorityCustomOverCoding() {
        let cat = catalog(extra: [entry("deploy", priority: 60)], designs: [design("deploy")])
        let active = pick(cat, coding: true)
        XCTAssertEqual(active.kind, "custom")
        XCTAssertEqual(active.id, "deploy")
    }

    func testLowerPriorityCustomLosesToCoding() {
        let cat = catalog(extra: [entry("deploy", priority: 20)], designs: [design("deploy")])
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
    }

    func testDisabledCustomIsSkipped() {
        let cat = catalog(extra: [entry("deploy", enabled: false, priority: 99)],
                          designs: [design("deploy")])
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
    }

    func testCustomWithUnmetConditionIsSkipped() {
        let cat = catalog(
            extra: [entry("deploy", priority: 99,
                          conditions: ["op": "gt", "a": ["src": "battery.level"], "b": 20])],
            designs: [design("deploy")])
        // No battery in sources → condition false → coding wins.
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
        // Battery high → custom wins.
        XCTAssertEqual(pick(cat, coding: true, sources: ["battery.level": 80]).id, "deploy")
    }

    func testNothingLiveGivesNone() {
        XCTAssertEqual(pick(catalog()).kind, "none")
        XCTAssertNil(pick(catalog()).id)
    }

    func testScheduleOutsideWindowExcludesTheDesign() {
        let cat = catalog(
            extra: [entry("night", priority: 99, schedule: ["from": "22:00", "to": "23:00"])],
            designs: [design("night")])
        // 14:00 is outside 22–23 → falls back to coding.
        XCTAssertEqual(pick(cat, coding: true).kind, "coding")
    }

    func testScheduleInsideWindowIncludesTheDesign() {
        let cat = catalog(
            extra: [entry("work", priority: 99,
                          schedule: ["days": [5], "from": "09:00", "to": "17:00"])],
            designs: [design("work")])
        XCTAssertEqual(pick(cat, coding: true).id, "work")   // Friday(5) 14:00 → in window
    }

    // MARK: scheduleMatches (exercised directly)

    func testScheduleNilOrEmptyIsAlways() {
        XCTAssertTrue(IslandAuto.scheduleMatches(nil, now))
        XCTAssertTrue(IslandAuto.scheduleMatches([:], now))
    }

    func testSchedulePartialWindowLeavesTheTimeCheckOpen() {
        XCTAssertTrue(IslandAuto.scheduleMatches(["from": "09:00"], now))
        XCTAssertTrue(IslandAuto.scheduleMatches(["to": "17:00"], now))
        XCTAssertTrue(IslandAuto.scheduleMatches(["from": "nope", "to": "17:00"], now))
    }

    func testScheduleWrapsPastMidnight() {
        // 22:00 → 06:00 must include 23:30 and 02:00 but not 14:00.
        let window: JSONObject = ["from": "22:00", "to": "06:00"]
        XCTAssertFalse(IslandAuto.scheduleMatches(window, now))
        XCTAssertTrue(IslandAuto.scheduleMatches(window, at(23, 30)))
        XCTAssertTrue(IslandAuto.scheduleMatches(window, at(2, 0)))
    }

    func testScheduleDaysAcceptNumbersAndNumericStrings() {
        XCTAssertTrue(IslandAuto.scheduleMatches(["days": [5]], now))
        XCTAssertTrue(IslandAuto.scheduleMatches(["days": ["5"]], now))
        XCTAssertFalse(IslandAuto.scheduleMatches(["days": [1, 2]], now))
        // Sunday must map to 7, not Foundation's 1.
        XCTAssertEqual(IslandAuto.isoWeekday(sunday), 7)
        XCTAssertTrue(IslandAuto.scheduleMatches(["days": [7]], sunday))
    }

    func testScheduleBoundsAreInclusive() {
        let window: JSONObject = ["from": "14:00", "to": "14:00"]
        XCTAssertTrue(IslandAuto.scheduleMatches(window, now))
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private var sunday: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 21   // the Sunday after the fixture Friday
        components.hour = 12
        return Calendar.current.date(from: components)!
    }
}
