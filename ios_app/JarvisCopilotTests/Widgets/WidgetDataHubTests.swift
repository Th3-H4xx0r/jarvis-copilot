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

}
