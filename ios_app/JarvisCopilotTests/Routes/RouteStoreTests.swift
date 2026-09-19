import XCTest
@testable import JarvisCopilot

/// Routes on the phone: kept at once, queued for the server until it takes
/// them, and fetched back for a workout this phone never recorded.
@MainActor
final class RouteStoreTests: XCTestCase {
    private var store: RouteStore!
    private var transport: MockTransport!
    private var client: HealthClient!

    override func setUp() async throws {
        store = RouteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Routes-\(UUID().uuidString)"))
        transport = MockTransport()
        client = HealthClient(api: JarvisAPI(credentials: TestCredentials(), transport: transport), spaceID: "jarvis-health")
    }

    private func workout(_ route: WorkoutRoute) -> RingWorkout {
        var w = RingWorkout(sport: 7, sportName: "Run", start: route.start, end: route.start.addingTimeInterval(1400),
                            activeSeconds: 1300, steps: 0, distanceMeters: 4200, distanceSource: "gps", kilocalories: 300,
                            heartRateAverage: nil, heartRateMax: nil, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0])
        w.route = RouteMath.summary(route)
        return w
    }

    func testARouteIsKeptListedAndQueued() {
        let route = SampleRoute.route()
        store.save(route, for: workout(route), deviceID: "b6ce93c4")
        XCTAssertEqual(store.route(start: route.start)?.points.count, route.points.count)
        XCTAssertEqual(store.index.first?.sportName, "Run")
        XCTAssertEqual(store.pending().count, 1)
        // A second store over the same folder sees it all (a relaunch).
        let again = RouteStore(directory: store.directory)
        XCTAssertEqual(again.index.count, 1)
        XCTAssertTrue(again.hasRoute(start: route.start))
        again.delete(start: route.start)
        XCTAssertNil(again.route(start: route.start))
        XCTAssertTrue(again.index.isEmpty)
        XCTAssertTrue(again.pending().isEmpty)
    }

    func testAFailedUploadStaysForNextTime() async {
        let route = SampleRoute.route()
        store.save(route, for: workout(route), deviceID: "b6ce93c4")
        transport.enqueue(json: ["error": "down"], status: 502)
        await store.flush(client: client)
        XCTAssertEqual(store.pending().count, 1)
        transport.enqueue(json: ["ok": true, "points": 10])
        await store.flush(client: client)
        XCTAssertTrue(store.pending().isEmpty)
        let body = transport.lastBody()
        XCTAssertEqual(body["device_id"] as? String, "b6ce93c4")
        XCTAssertEqual(body["start"] as? String, HealthClient.instant.string(from: route.start))
        let sent = (body["route"] as? [String: Any])?["segments"] as? [[[Any]]]
        XCTAssertEqual(sent?.count, 2)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/integrations/jarvis-health/health/workouts/route")
    }

    func testAMissingRouteComesFromTheServerAndStays() async throws {
        let route = SampleRoute.route()
        var saved = workout(route)
        saved.device = "ring-b6ce93c4"
        let wire = try HealthClient.serverJSON(route)
        transport.enqueue(json: ["route": wire])
        let loaded = await store.load(saved, client: client)
        XCTAssertEqual(loaded?.points.count, route.points.count)
        XCTAssertEqual(loaded?.start.timeIntervalSince1970 ?? 0, route.start.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(transport.lastRequest?.url?.query?.contains("device=ring-b6ce93c4") ?? false)
        // Cached: no second request.
        _ = await store.load(saved, client: client)
        XCTAssertEqual(transport.requests.count, 1)
        // A workout without a route never asks.
        var plain = saved
        plain.start = plain.start.addingTimeInterval(-86_400)
        plain.route = nil
        let none = await store.load(plain, client: client)
        XCTAssertNil(none)
        XCTAssertEqual(transport.requests.count, 1)
    }
}
