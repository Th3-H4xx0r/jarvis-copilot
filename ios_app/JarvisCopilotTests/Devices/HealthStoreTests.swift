import XCTest
@testable import JarvisCopilot

/// The phone caches what the server computed, shows it offline, and says when
/// it is old. It never computes a score itself.
@MainActor
final class HealthStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(date: String = "2026-09-17", health: Int? = 78, stale: Bool = false,
                         analysis: String = "Short night, strong HRV.") -> [String: Any] {
        func part(_ value: Int?, _ band: String) -> [String: Any] {
            ["value": value as Any? ?? NSNull(), "band": band, "points": [], "missing": []]
        }
        return [
            "date": date,
            "health": part(health, "Good"),
            "sleep": part(71, "Good"),
            "recovery": part(nil, "—"),
            "body": part(80, "Good"),
            "activity": part(62, "Fair"),
            "analysis": analysis,
            "stale": stale,
            "baseline_days": 14,
            "model": "claude-opus-5",
            "generated_at": "2026-09-17T17:00:00Z",
        ]
    }

    private func store(_ transport: FakeHealthTransport) -> HealthStore {
        HealthStore(spaceID: "wearable-ring-test",
                    client: HealthClient(api: transport.api, spaceID: "wearable-ring-test"),
                    directory: directory)
    }

    func testTheSpaceIdMatchesWhatTheServerDerives() {
        XCTAssertEqual(HealthSpace.id(forRing: "B6CE93C4-5680-B0C5-A3AA-32D3DD349E20"), "wearable-ring-b6ce93c4")
        XCTAssertEqual(HealthSpace.id(kind: "ring", deviceID: "b6ce93c4"), "wearable-ring-b6ce93c4")
    }

    func testARefreshPublishesTheScoresAndTheirContributions() async {
        let transport = FakeHealthTransport()
        transport.scores = payload()
        let store = store(transport)

        await store.refresh(date: "2026-09-17")

        let scores = store.scores(for: "2026-09-17")
        XCTAssertEqual(scores?.health.value, 78)
        XCTAssertEqual(scores?.health.band, "Good")
        XCTAssertEqual(scores?.analysis, "Short night, strong HRV.")
        XCTAssertEqual(scores?.recovery.value, nil, "a part the server could not score stays empty")
        XCTAssertNil(store.lastError)
    }

    func testTheCacheServesTheCardWhenTheServerCannotBeReached() async {
        let transport = FakeHealthTransport()
        transport.scores = payload()
        let first = store(transport)
        await first.refresh(date: "2026-09-17")

        transport.failNext = true
        let second = store(transport)
        await second.refresh(date: "2026-09-17")

        XCTAssertEqual(second.scores(for: "2026-09-17")?.health.value, 78, "the cached day still renders")
        XCTAssertNotNil(second.lastError, "and the failure is kept so the card can mention it")
    }

    func testAServerSideStaleFlagIsHonouredWhateverTheCacheSays() async {
        let transport = FakeHealthTransport()
        transport.scores = payload(stale: true)
        let store = store(transport)

        await store.refresh(date: "2026-09-17")

        XCTAssertTrue(store.isStale("2026-09-17"))
    }

    func testAFreshFetchIsNotStale() async {
        let transport = FakeHealthTransport()
        transport.scores = payload()
        let store = store(transport)

        await store.refresh(date: "2026-09-17")

        XCTAssertFalse(store.isStale("2026-09-17"))
        XCTAssertEqual(store.age(of: "2026-09-17").map { $0 < 5 }, true)
    }

    func testADayWithNoScoresYetLeavesTheCardEmptyRatherThanErroring() async {
        let transport = FakeHealthTransport()
        transport.scores = nil
        let store = store(transport)

        await store.refresh(date: "2026-09-17")

        XCTAssertNil(store.scores(for: "2026-09-17"))
        XCTAssertNil(store.lastError)
    }

    func testEverySettingsWriteDeclaresItCameFromTheWearableScreen() async {
        let transport = FakeHealthTransport()
        let store = store(transport)

        _ = await store.updateSettings(["frequency": "hourly"])

        let body = transport.lastPostBody ?? [:]
        XCTAssertEqual(body["source"] as? String, HealthClient.settingsSource)
        XCTAssertEqual(body["frequency"] as? String, "hourly")
    }

    func testAFailedWriteIsReportedAndLeavesTheOldSettingsInPlace() async {
        let transport = FakeHealthTransport()
        let store = store(transport)
        _ = await store.updateSettings(["frequency": "hourly"])
        let before = store.settings

        transport.failNext = true
        let ok = await store.updateSettings(["frequency": "manual"])

        XCTAssertFalse(ok)
        XCTAssertEqual(store.settings, before)
        XCTAssertNotNil(store.lastError)
    }

    func testTheWidgetSnapshotRoundTripsThroughTheSharedGroup() {
        let snapshot = HealthSnapshot(date: "2026-09-17", health: 78, band: "Good", sleep: 71,
                                      recovery: nil, body: 80, activity: 62,
                                      analysis: "Short night.", generatedAt: Date(), stale: false)
        snapshot.write()

        let back = HealthSnapshot.read()
        XCTAssertEqual(back?.health, 78)
        XCTAssertEqual(back?.value(for: .sleep), 71)
        XCTAssertNil(back?.value(for: .recovery))
    }
}

/// A transport that answers the health endpoints from fixtures.
@MainActor
final class FakeHealthTransport {
    var scores: [String: Any]?
    var settings: [String: Any] = [
        "enabled": true, "model": "", "provider": "", "frequency": "every 6 hours",
        "quiet_hours": ["start": "22:00", "end": "08:00"],
        "rules": ["short_sleep": ["enabled": true, "threshold": 5]],
        "goals": ["steps": 10000, "active_minutes": 30],
    ]
    var failNext = false
    var lastPostBody: [String: Any]?

    lazy var api = JarvisAPI(credentials: Credentials(), transport: Transport(owner: self))

    struct Credentials: APICredentials {
        var baseURL: URL? { URL(string: "https://example.invalid") }
        var headers: [String: String] { ["Cookie": "test"] }
    }

    struct Transport: APITransport {
        let owner: FakeHealthTransport

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            return try await MainActor.run {
                if owner.failNext {
                    owner.failNext = false
                    throw APIError.badResponse("no network")
                }
                if method == "POST", let body = request.httpBody {
                    owner.lastPostBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                }
                var payload: [String: Any] = [:]
                if path.hasSuffix("/settings") {
                    if method == "POST", let updates = owner.lastPostBody {
                        for (key, value) in updates where key != "source" { owner.settings[key] = value }
                    }
                    payload = ["settings": owner.settings]
                } else if path.contains("/day/") {
                    payload = ["scores": owner.scores as Any? ?? NSNull()]
                } else if path.hasSuffix("/run") {
                    payload = ["run": ["scored_date": "2026-09-17"]]
                } else {
                    payload = ["ok": true]
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        }

        func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
            throw APIError.badResponse("not used")
        }
    }
}
