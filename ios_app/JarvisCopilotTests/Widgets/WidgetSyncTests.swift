import XCTest
@testable import JarvisCopilot

/// Widget designs kept in step with the server: pulled into the App Group cache, saved locally
/// first and pushed, deletions carried both ways.
@MainActor
final class WidgetSyncTests: XCTestCase {

    final class FakeServer: WidgetDesignsServing {
        var stored: [String: Data] = [:]
        var reachable = true
        var catalog: [[String: Any]] = []
        var rejects = false

        private func check() throws { if !reachable { throw APIError.http(status: 502, message: "down") } }

        func designs() async throws -> [Data] { try check(); return Array(stored.values) }

        func upsert(_ design: Data) async throws -> WidgetUpsert {
            try check()
            if rejects { throw APIError.http(status: 400, message: "presentations: needs at least one size") }
            let object = try JSONSerialization.jsonObject(with: design) as! [String: Any]
            stored[object["id"] as! String] = design
            return WidgetUpsert(saved: design, warnings: ["health.nope is not in the catalog"])
        }

        func delete(_ id: String) async throws { try check(); stored[id] = nil }

        func postCatalog(_ entries: [[String: Any]]) async throws { try check(); catalog = entries }
    }

    private var dir: URL!
    private var defaults: UserDefaults!
    private var server: FakeServer!
    private var reloads = 0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-sync-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "WidgetSyncTests-\(UUID().uuidString)")
        server = FakeServer()
        reloads = 0
    }

    private func sync() -> WidgetSync {
        WidgetSync(server: server, directory: dir, defaults: defaults, reload: { [unowned self] in reloads += 1 },
                   buttons: { [ControlButtonInfo(id: "B1", name: "Lights", symbol: "lightbulb.fill", keepsState: true)] })
    }

    private func design(_ id: String, name: String = "D") -> Data {
        Data(#"{"schema":1,"id":"\#(id)","name":"\#(name)","presentations":{"small":{"type":"text","value":"x"}}}"#.utf8)
    }

    func testPullingCachesTheServersDesignsAndReloadsTheWidgets() async {
        server.stored = ["a": design("a"), "b": design("b")]
        await sync().pull()
        XCTAssertEqual(Set(WidgetDesignCache.infos(in: dir).map(\.id)), ["a", "b"])
        XCTAssertEqual(reloads, 1)
    }

    func testADesignDeletedOnTheServerLeavesThePhone() async {
        try? WidgetDesignCache.save(design("gone"), in: dir)
        server.stored = ["kept": design("kept")]
        await sync().pull()
        XCTAssertEqual(WidgetDesignCache.infos(in: dir).map(\.id), ["kept"])
    }

    func testASaveIsLocalFirstThenPushedWithTheServersWarnings() async throws {
        let outcome = try await sync().save(design("mine"))
        XCTAssertEqual(outcome, .saved(warnings: ["health.nope is not in the catalog"]))
        XCTAssertNotNil(WidgetDesignCache.load("mine", in: dir))
        XCTAssertNotNil(server.stored["mine"])
    }

    func testASaveWhileOfflineStaysLocalAndIsPushedLater() async throws {
        server.reachable = false
        let s = sync()
        let outcome = try await s.save(design("offline"))
        guard case .local = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotNil(WidgetDesignCache.load("offline", in: dir))
        await s.pull()
        XCTAssertNotNil(WidgetDesignCache.load("offline", in: dir), "a pull can't drop an unpushed design")
        server.reachable = true
        await s.sync()
        XCTAssertNotNil(server.stored["offline"])
    }

    func testADesignTheServerRejectsSaysWhy() async throws {
        server.rejects = true
        let outcome = try await sync().save(design("bad"))
        XCTAssertEqual(outcome, .rejected("presentations: needs at least one size"))
    }

    func testDeletingRemovesItHereAndOnTheServer() async {
        server.stored = ["x": design("x")]
        let s = sync()
        await s.pull()
        await s.delete("x")
        XCTAssertTrue(WidgetDesignCache.infos(in: dir).isEmpty)
        XCTAssertNil(server.stored["x"])
    }

    func testTheCatalogPostedIncludesTheDataKeysAndTheButtons() async {
        await sync().sync()
        let keys = server.catalog.compactMap { $0["key"] as? String }
        XCTAssertTrue(keys.contains("health.steps"))
        XCTAssertTrue(keys.contains("controls.B1"))
        XCTAssertEqual(server.catalog.first { $0["key"] as? String == "controls.B1" }?["kind"] as? String, "toggle")
    }
}
