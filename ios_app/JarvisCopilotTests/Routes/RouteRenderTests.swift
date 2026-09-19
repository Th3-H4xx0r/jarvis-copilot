import SwiftUI
import XCTest
@testable import JarvisCopilot

/// A loop along Austin's Lady Bird Lake: the route the route screens are drawn with.
enum SampleRoute {
    /// Eighteen minutes ago, so a live screen's clock reads like one.
    static let start = Date().addingTimeInterval(-1080)

    /// (lat, lon, elevation) every two seconds at about 3 m/s, `seconds` long.
    static func loop(seconds: Int) -> [(lat: Double, lon: Double, ele: Double, t: Double)] {
        let center = (lat: 30.2625, lon: -97.7545)
        return stride(from: 0, through: seconds, by: 2).map { s in
            let angle = Double(s) / 1400 * 2 * .pi
            // A rounded, lopsided loop, not a circle.
            let r = 700 + 180 * sin(angle * 2) + 60 * cos(angle * 5)
            let lat = center.lat + r * sin(angle) / 111_195
            let lon = center.lon + 1.6 * r * cos(angle) / (111_195 * cos(center.lat * .pi / 180))
            let ele = 150 + 18 * sin(angle * 1.5) + 6 * sin(angle * 7)
            return (lat, lon, ele, Double(s))
        }
    }

    static func route(seconds: Int = 1400, hr: Bool = true) -> WorkoutRoute {
        let points = loop(seconds: seconds).map { p in
            RoutePoint(t: p.t, lat: p.lat, lon: p.lon, ele: p.ele,
                       hr: hr ? 132 + Int(18 * sin(p.t / 180)) + Int(p.t / 60) : nil, speed: nil)
        }
        // A pause a third of the way round.
        let cut = points.count / 3
        return WorkoutRoute(start: start, segments: [Array(points[..<cut]), Array(points[cut...])],
                            elevationSource: "barometer")
    }
}

@MainActor
final class RouteRenderTests: XCTestCase {
    private var link: FakeRingLink!
    private var location: FakeLocation!
    private var defaults: UserDefaults!
    private var clock = SampleRoute.start

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: "RouteRenderTests")
        defaults = UserDefaults(suiteName: "RouteRenderTests")!
        link = FakeRingLink()
        location = FakeLocation()
        DistanceUnit.current = .mi
        MapStyle.current = .standard
    }

    override func tearDown() async throws {
        WorkoutMonitorPreference.usesRing = true
    }

    /// A run 18 minutes in.
    private func running(phoneOnly: Bool) async throws -> RingWorkoutController {
        let session = RingSession(transport: makeRingTransport(link), defaults: defaults)
        let c = RingWorkoutController(session: session, ensureConnected: { true }, location: location,
                                      clock: { [unowned self] in self.clock }, defaults: defaults)
        c.countdownSeconds = 0
        c.startTimeout = 60
        WorkoutMonitorPreference.usesRing = !phoneOnly
        c.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 60_000_000)
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * (n - 1 - $0))) & 0xFF) } }
        for p in SampleRoute.loop(seconds: 1080) {
            if !phoneOnly {
                let s = Int(p.t) + 1
                link.deliver(RingProtocol.frame(0x78, [7, 2] + be(s, 2) + [UInt8(138 + (s / 40) % 20)] + be(s * 3 / 2, 3)
                                                + be(s * 3, 3) + be(s * 190, 3)))
            }
            location.fix(lat: p.lat, lon: p.lon, at: SampleRoute.start.addingTimeInterval(p.t), altitude: p.ele)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        clock = SampleRoute.start.addingTimeInterval(1080)
        return c
    }

    func testTheLiveRunWithTheRing() async throws {
        let c = try await running(phoneOnly: false)
        try RenderHarness.write(RouteLiveView(workout: c), size: CGSize(width: 402, height: 874), name: "route-live",
                                settle: 5)
    }

    func testTheLiveRunOnThePhoneAlone() async throws {
        let c = try await running(phoneOnly: true)
        try RenderHarness.write(RouteLiveView(workout: c), size: CGSize(width: 402, height: 874),
                                name: "route-live-phone", settle: 12)
    }

    func testTheLiveMapFullScreen() async throws {
        let c = try await running(phoneOnly: true)
        MapStyle.current = .satellite
        try RenderHarness.write(RouteLiveView(workout: c, expanded: true), size: CGSize(width: 402, height: 874),
                                name: "route-live-expanded", settle: 12)
        MapStyle.current = .standard
    }
}
