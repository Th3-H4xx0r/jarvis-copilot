import XCTest
@testable import JarvisCopilot

/// The data hub: every area's values in one App Group snapshot, without burning the
/// widget reload budget.
@MainActor
final class WidgetDataHubTests: XCTestCase {

    struct Fake: WidgetDataProvider {
        var values: [String: JCJSON]
        func values() async -> [String: JCJSON] { values }
    }

    final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private var written: [[String: JCJSON]] = []
    private var reloads = 0
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        written = []
        reloads = 0
        clock = Date(timeIntervalSince1970: 1_000_000)
    }

    private func hub(_ providers: [any WidgetDataProvider]) -> WidgetDataHub {
        WidgetDataHub(providers: providers,
                      write: { [unowned self] in written.append($0) },
                      reload: { [unowned self] in reloads += 1 },
                      now: { [unowned self] in clock })
    }

    func testEveryProvidersValuesLandInOneSnapshot() async {
        let h = hub([Fake(values: ["health.steps": .number(7312)]), Fake(values: ["x5ring.battery": .number(80)])])
        await h.refresh()
        XCTAssertEqual(written.last?["health.steps"], .number(7312))
        XCTAssertEqual(written.last?["x5ring.battery"], .number(80))
        XCTAssertNotNil(written.last?["time.updated"])
    }

    func testAnEmptyProviderLeavesTheOthers() async {
        let h = hub([Fake(values: [:]), Fake(values: ["chat.last_reply": .string("Done")])])
        await h.refresh()
        XCTAssertEqual(written.last?["chat.last_reply"], .string("Done"))
    }

    func testTheFirstSnapshotReloadsTheWidgets() async {
        await hub([Fake(values: ["a.b": .number(1)])]).refresh()
        XCTAssertEqual(reloads, 1)
    }

    func testAChangeWithinFiveMinutesWaitsAndThenReloadsOnce() async {
        let source = Box<[String: JCJSON]>(["health.hr_latest": .number(60)])
        struct Live: WidgetDataProvider {
            let box: Box<[String: JCJSON]>
            func values() async -> [String: JCJSON] { box.value }
        }
        let h = hub([Live(box: source)])
        await h.refresh()
        source.value = ["health.hr_latest": .number(90)]
        clock += 60
        await h.refresh()
        XCTAssertEqual(reloads, 1, "a minute later is too soon")
        clock += 300
        await h.refresh()
        XCTAssertEqual(reloads, 2, "the change is shown once the spacing has passed")
        clock += 300
        await h.refresh()
        XCTAssertEqual(reloads, 2, "nothing new since the last reload")
    }

    func testOnlyTheClockChangingIsNotAChange() async {
        let h = hub([Fake(values: ["a.b": .number(1)])])
        await h.refresh()
        clock += 3600
        await h.refresh()
        XCTAssertEqual(reloads, 1)
    }

    func testATinyWobbleInANumberIsNotAChange() {
        XCTAssertFalse(WidgetDataHub.changed(["s": .number(10_000)], ["s": .number(10_050)]))
        XCTAssertTrue(WidgetDataHub.changed(["s": .number(10_000)], ["s": .number(10_500)]))
        XCTAssertTrue(WidgetDataHub.changed(["s": .string("a")], ["s": .string("b")]))
        XCTAssertTrue(WidgetDataHub.changed([:], ["s": .bool(true)]))
    }

    func testTheSnapshotFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-data-\(UUID().uuidString).json")
        WidgetDataFile.write(["health.steps": .number(5), "chat.last_reply": .string("hi")], to: url)
        XCTAssertEqual(WidgetDataFile.read(from: url)["health.steps"], .number(5))
        XCTAssertEqual(WidgetDataFile.read(from: FileManager.default.temporaryDirectory.appendingPathComponent("none.json")), [:])
    }

    func testTheCatalogNamesEveryAreaAndHasNoDuplicates() {
        let keys = WidgetDataCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
        for area in ["health", "chat", "coding", "server", "phone", "time"] {
            XCTAssertFalse(WidgetDataCatalog.entries(area: area).isEmpty, area)
        }
        XCTAssertTrue(keys.contains("x5ring.battery"))
        XCTAssertTrue(keys.contains("health.steps_week"))
        XCTAssertEqual(WidgetDataCatalog.entry("health.steps_week")?.kind, .series)
    }

    // MARK: review fixes

    func testOverlappingRefreshesNeverRunAtOnce() async {
        final class Slow: WidgetDataProvider {
            var running = 0
            var most = 0
            var calls = 0
            func values() async -> [String: JCJSON] {
                running += 1
                most = max(most, running)
                calls += 1
                try? await Task.sleep(for: .milliseconds(30))
                running -= 1
                return ["a.b": .number(Double(calls))]
            }
        }
        let slow = Slow()
        let h = hub([slow])
        async let first: Void = h.refresh()
        async let second: Void = h.refresh()
        _ = await (first, second)
        XCTAssertEqual(slow.most, 1)
        XCTAssertEqual(written.last?["a.b"], .number(Double(slow.calls)), "the newest values are the ones kept")
    }

    // MARK: server areas (a push names what changed)

    final class Counting: WidgetDataProvider {
        let area: String?
        var calls = 0
        init(_ area: String) { self.area = area }
        func values() async -> [String: JCJSON] {
            calls += 1
            return ["\(area ?? "").calls": .number(Double(calls))]
        }
    }

    func testABackgroundPushRefetchesOnlyTheAreaItNames() async {
        let health = Counting("health"), coding = Counting("coding")
        let h = hub([health, coding])
        await h.refresh()
        h.setForeground(false)
        clock += WidgetDataHub.backgroundAreaEvery
        h.pushed(["what": ["coding"]])
        await h.refresh()
        XCTAssertEqual(coding.calls, 2)
        XCTAssertEqual(health.calls, 1, "a coding change does not refetch seven health histories")
        XCTAssertEqual(written.last?["health.calls"], .number(1), "an area not asked keeps showing its values")
    }

    func testInTheBackgroundAPushedChangeWaitsUntilTheAreaIsAnHourOld() async {
        let coding = Counting("coding")
        let h = hub([coding])
        await h.refresh()
        h.setForeground(false)
        clock += 600
        h.pushed(["what": ["coding"]])
        await h.refresh()
        XCTAssertEqual(coding.calls, 1, "asked ten minutes ago: held")
        clock += WidgetDataHub.backgroundAreaEvery
        await h.refresh()
        XCTAssertEqual(coding.calls, 2, "the held change goes once the hour is up")
        await h.refresh()
        XCTAssertEqual(coding.calls, 2, "and only once")
    }

    func testAnUnlockFetchesWhatChangedAtOnceAndLeavesTheRest() async {
        let health = Counting("health"), coding = Counting("coding")
        let h = hub([health, coding])
        await h.refresh()
        h.setForeground(false)
        clock += 60
        h.pushed(["what": ["coding"]])
        h.unlocked()
        await h.refresh()
        XCTAssertEqual(coding.calls, 2)
        XCTAssertEqual(health.calls, 1, "unchanged and a minute old: not asked")
    }

    func testAnUnlockAlsoRefreshesAnAreaNobodyPushesForOnceItIsHalfAnHourOld() async {
        let chat = Counting("chat")
        let h = hub([chat])
        await h.refresh()
        h.setForeground(false)
        clock += WidgetDataHub.unlockStaleAfter
        await h.refresh()
        XCTAssertEqual(chat.calls, 1, "no unlock: waits for the two-hour mark")
        h.unlocked()
        await h.refresh()
        XCTAssertEqual(chat.calls, 2)
        clock += WidgetDataHub.backgroundFullEvery
        await h.refresh()
        XCTAssertEqual(chat.calls, 3, "and without an unlock, every two hours")
    }

    func testAPushNamingNoAreaMarksThemAll() async {
        let health = Counting("health"), coding = Counting("coding")
        let h = hub([health, coding])
        await h.refresh()
        h.setForeground(false)
        clock += WidgetDataHub.backgroundAreaEvery
        h.pushed([:])
        await h.refresh()
        XCTAssertEqual([health.calls, coding.calls], [2, 2])
    }

    func testOnScreenEveryAreaIsAskedEachPass() async {
        let health = Counting("health"), local = Fake(values: ["phone.battery": .number(50)])
        let h = hub([health, local])
        await h.refresh()
        await h.refresh()
        XCTAssertEqual(health.calls, 2, "each provider's own cache bounds the requests on screen")
        XCTAssertEqual(written.last?["phone.battery"], .number(50))
    }

    func testAKeyAProviderStopsGivingIsDropped() async {
        struct Live: WidgetDataProvider {
            let box: Box<[String: JCJSON]>
            var area: String? { "coding" }
            func values() async -> [String: JCJSON] { box.value }
        }
        let source = Box<[String: JCJSON]>(["coding.lead_agent": .string("claude"), "coding.total": .number(1)])
        let h = hub([Live(box: source)])
        await h.refresh()
        source.value = ["coding.total": .number(0)]
        await h.refresh()
        XCTAssertNil(written.last?["coding.lead_agent"])
        XCTAssertEqual(written.last?["coding.total"], .number(0))
    }
}
