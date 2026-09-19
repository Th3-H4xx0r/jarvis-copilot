import CoreLocation
import XCTest
@testable import JarvisCopilot

/// A GPS stand-in: fixes are handed to it, it records exactly as the real one.
@MainActor
final class FakeLocation: WorkoutLocationTracking {
    private(set) var recording: RouteRecording?
    private var update: ((RouteProgress) -> Void)?
    private(set) var started: [(sport: Int, resuming: Bool)] = []
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var stops = 0
    var heartRate: (() -> Int?)?
    var steps: Int? = 1234
    var cadence: Int?
    var lastFix: CLLocationCoordinate2D?
    var route: WorkoutRoute? { recording?.route }
    var progress: RouteProgress { recording?.progress ?? RouteProgress() }

    func start(sport: Int, weightKg: Double, at start: Date, resuming: Bool, update: @escaping (RouteProgress) -> Void) {
        started.append((sport, resuming))
        recording = RouteRecording(start: start, sport: sport, weightKg: weightKg)
        self.update = update
    }

    func pause() { pauses += 1; recording?.pause() }
    func resume() { resumes += 1; recording?.resume() }

    func stop() -> WorkoutRoute? {
        stops += 1
        let route = recording?.route
        recording = nil
        return (route?.points.count ?? 0) >= 2 ? route : nil
    }

    /// A fix at a place and time.
    func fix(lat: Double, lon: Double, at time: Date, altitude: Double? = nil) {
        let fix = RouteFix(time: time, lat: lat, lon: lon, horizontalAccuracy: 5, altitude: altitude,
                           verticalAccuracy: altitude == nil ? nil : 4, speed: nil)
        if recording?.take(fix, heartRate: heartRate?(), pressureAltitude: altitude, now: time) == true {
            lastFix = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        update?(progress)
    }

    /// A fix `meters` north of the start, at `time`.
    func fix(_ meters: Double, at time: Date, altitude: Double? = nil) {
        let fix = RouteFix(time: time, lat: 40 + meters / RouteMathTests.metersPerDegree, lon: -105,
                           horizontalAccuracy: 5, altitude: altitude, verticalAccuracy: altitude == nil ? nil : 4,
                           speed: nil)
        _ = recording?.take(fix, heartRate: heartRate?(), pressureAltitude: nil, now: time)
        update?(progress)
    }
}

/// Outdoor workouts: phone-only on the phone's clock, the route pausing with
/// the workout, and a route on the summary.
@MainActor
final class OutdoorWorkoutTests: XCTestCase {
    private var link: FakeRingLink!
    private var ring: RingSession!
    private var location: FakeLocation!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let run = RingSport.withID(7)

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: "OutdoorWorkoutTests")
        defaults = UserDefaults(suiteName: "OutdoorWorkoutTests")!
        link = FakeRingLink()
        ring = RingSession(transport: makeRingTransport(link), defaults: defaults)
        location = FakeLocation()
    }

    override func tearDown() async throws {
        WorkoutMonitorPreference.usesRing = true
    }

    private func controller() -> RingWorkoutController {
        let c = RingWorkoutController(session: ring, ensureConnected: { true }, location: location,
                                      profile: { VitalsProfile(age: 30, female: false, weightKg: 70, heightCm: 178, restingHR: 60) },
                                      clock: { [unowned self] in self.clock }, defaults: defaults)
        c.countdownSeconds = 0
        c.startTimeout = 30
        return c
    }

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private func startPhoneOnly(_ c: RingWorkoutController) async throws {
        WorkoutMonitorPreference.usesRing = false
        c.start(run)
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    func testAPhoneOnlyRunNeverTalksToTheRing() async throws {
        let c = controller()
        try await startPhoneOnly(c)
        XCTAssertEqual(c.phase, .running)
        XCTAssertTrue(c.phoneOnly)
        XCTAssertEqual(location.started.first?.sport, 7)
        for s in stride(from: 0.0, through: 100, by: 2) { location.fix(s * 3, at: at(s)) }
        XCTAssertEqual(c.routeProgress.distance, 300, accuracy: 3)
        XCTAssertEqual(c.gpsDistance ?? 0, 300, accuracy: 3)
        XCTAssertEqual(c.elapsed(at: at(100)), 100)
        XCTAssertTrue(link.payloads(0x77).isEmpty, "the ring is left alone")
    }

    func testPausingStopsTheClockAndTheRoute() async throws {
        let c = controller()
        try await startPhoneOnly(c)
        for s in stride(from: 0.0, through: 100, by: 2) { location.fix(s * 3, at: at(s)) }
        clock = at(100)
        c.pause()
        XCTAssertEqual(c.phase, .paused)
        XCTAssertEqual(location.pauses, 1)
        location.fix(900, at: at(130))
        XCTAssertEqual(c.elapsed(at: at(160)), 100, "the clock stands still")
        clock = at(160)
        c.resume()
        XCTAssertEqual(location.resumes, 1)
        for s in stride(from: 160.0, through: 220, by: 2) { location.fix(1000 + (s - 160) * 3, at: at(s)) }
        XCTAssertEqual(c.elapsed(at: at(220)), 160)
        XCTAssertEqual(c.routeProgress.distance, 480, accuracy: 5, "nothing across the pause")
        clock = at(220)
        c.end()
        guard case .finished(let workout) = c.phase else { return XCTFail("a summary") }
        XCTAssertEqual(workout.activeSeconds, 160)
        XCTAssertEqual(workout.distanceSource, "gps")
        XCTAssertEqual(workout.steps, 1234, "the phone's pedometer")
        XCTAssertEqual(workout.kcalSource, "estimate")
        XCTAssertGreaterThan(workout.kilocalories, 5)
        XCTAssertEqual(workout.route?.distanceMeters ?? 0, 480, accuracy: 5)
        XCTAssertEqual(c.finishedRoute?.segments.count, 2)
        var saved: (WorkoutRoute, RingWorkout)?
        c.onSaveRoute = { saved = ($0, $1) }
        c.close(save: true)
        XCTAssertEqual(saved?.1.start, workout.start)
        XCTAssertNil(c.finishedRoute)
        XCTAssertFalse(c.phoneOnly)
        XCTAssertNil(RingWorkoutController.PhoneWorkout.load(defaults))
    }

    func testARelaunchPicksUpThePhoneOnlyWorkout() async throws {
        let first = controller()
        try await startPhoneOnly(first)
        clock = at(40)
        first.pause()
        XCTAssertNotNil(RingWorkoutController.PhoneWorkout.load(defaults))
        // The app is gone; a new one starts.
        let again = controller()
        XCTAssertTrue(again.phoneOnly)
        XCTAssertEqual(again.phase, .paused)
        XCTAssertEqual(location.started.last?.resuming, true)
        XCTAssertEqual(again.elapsed(at: at(500)), 40)
        clock = at(100)
        again.resume()
        XCTAssertEqual(again.elapsed(at: at(130)), 70)
    }

    func testTheRingsPauseAlsoPausesTheRoute() async throws {
        WorkoutMonitorPreference.usesRing = true
        let c = controller()
        c.start(run)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(c.phoneOnly)
        XCTAssertEqual(link.payloads(0x77).first.map { Array($0.prefix(2)) }, [1, 7])
        func tick(_ elapsed: Int) -> [UInt8] {
            func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * (n - 1 - $0))) & 0xFF) } }
            return [7, 2] + be(elapsed, 2) + [120] + be(elapsed * 3, 3) + be(elapsed * 3, 3) + be(elapsed * 100, 3)
        }
        for s in 1...5 { link.deliver(RingProtocol.frame(0x78, tick(s))) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .running)
        XCTAssertEqual(location.started.count, 1)
        XCTAssertEqual(location.heartRate?(), 120, "points carry the ring's reading")
        // The ring's clock stops: three still ticks are a pause.
        try await Task.sleep(nanoseconds: 2_600_000_000)
        for _ in 0..<4 { link.deliver(RingProtocol.frame(0x78, tick(5))) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .paused)
        XCTAssertEqual(location.pauses, 1)
        link.deliver(RingProtocol.frame(0x78, tick(6)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .running)
        XCTAssertEqual(location.resumes, 1)
    }

    func testTheRingsTicksDontReachAPhoneOnlyWorkout() async throws {
        let c = controller()
        try await startPhoneOnly(c)
        link.deliver(RingProtocol.frame(0x78, [7, 3, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .running, "an ended tick from the ring doesn't end it")
    }
}
