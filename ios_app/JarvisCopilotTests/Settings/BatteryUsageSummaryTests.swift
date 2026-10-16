import XCTest
@testable import JarvisCopilot

/// The arithmetic behind Settings → Battery usage.
final class BatteryUsageSummaryTests: XCTestCase {
    typealias Hour = EnergyLedger.Hour

    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func hour(_ index: Int, seconds: [String: Double] = [:], cpu: [String: Double] = [:],
                      counts: [String: Int] = [:], battery: (Double, Double)? = nil,
                      threads: [String: Double] = [:]) -> Hour {
        let start = t0.addingTimeInterval(Double(index) * 3600)
        return Hour(start: start, end: start.addingTimeInterval(3600), seconds: seconds, cpu: cpu, counts: counts,
                    batteryStart: battery?.0, batteryEnd: battery?.1, threads: threads)
    }

    func testTheRankingPutsTheBiggestPlaceFirstWithItsShares() {
        let summary = BatteryUsageSummary(hours: [
            hour(0, seconds: ["foreground": 600, "background": 3000, "where.health|Sleep": 300, "where.chat|": 300],
                 cpu: ["foreground": 150, "background": 50, "where.health|Sleep": 100, "where.chat|": 50]),
        ])
        let places = summary.byPlace
        XCTAssertEqual(places.map(\.title), ["Health › Sleep", "Chat", "In the background"])
        XCTAssertEqual(places[0].share, 1)
        XCTAssertEqual(places[1].share, 0.5, accuracy: 0.001)
        XCTAssertEqual(places[0].ofTotal, 0.5, accuracy: 0.001)
        XCTAssertEqual(places[0].detail, "5 min on screen")
    }

    func testDrainSkipsHoursOnTheChargerAndUnknownEnds() {
        let summary = BatteryUsageSummary(hours: [
            hour(0, battery: (0.9, 0.87)),
            hour(1, seconds: ["charging": 1200], battery: (0.87, 0.95)),
            hour(2),
            hour(3, battery: (0.95, 0.93)),
        ])
        XCTAssertEqual(summary.drained ?? 0, 5, accuracy: 0.001)
    }

    func testPocketDrainSplitsKeptAliveFromSuspendedHours() {
        let summary = BatteryUsageSummary(hours: [
            hour(0, seconds: ["background": 3600, "bg.keepalive": 3600, "bg.wifi": 3600], battery: (0.9, 0.88)),
            hour(1, seconds: ["background": 3600, "bg.keepalive": 3600, "bg.wifi": 3600], battery: (0.88, 0.86)),
            hour(2, seconds: ["background": 3600, "bg.cellular": 3600], battery: (0.86, 0.85)),
            hour(3, seconds: ["foreground": 3600], battery: (0.85, 0.75)),
        ])
        XCTAssertEqual(summary.pocketDrainKeptAlive ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(summary.pocketDrainSuspended ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(summary.pocketDrainWifi ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(summary.pocketDrainCellular ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(summary.screenDrain ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(summary.pocketDrain ?? 0, 5.0 / 3, accuracy: 0.001)
    }

    func testTheNetworkRankingCountsTheLiveLinkAlongsideRequests() {
        let summary = BatteryUsageSummary(hours: [
            hour(0, counts: ["net.Health history": 14, "net.bg.Health history": 14, "bytes.Health history": 2048,
                             "bridge.in": 90, "bridge.out": 90]),
        ])
        let rows = summary.network
        XCTAssertEqual(rows.first?.title, "Live link to Jarvis")
        XCTAssertEqual(rows.first?.value, 180)
        XCTAssertEqual(rows.last?.title, "Health history")
        XCTAssertTrue(rows.last?.detail?.hasPrefix("14 in the background") ?? false)
    }

    func testThreadsAreNamedForTheWorkTheyDo() {
        XCTAssertEqual(BatteryUsageSummary.work("main"), "App & screens")
        XCTAssertEqual(BatteryUsageSummary.work("com.apple.SwiftUI.AsyncRenderer"), "Animations & drawing")
        XCTAssertEqual(BatteryUsageSummary.work("com.apple.scenekit.scnview-renderer"), "3D models")
        XCTAssertEqual(BatteryUsageSummary.work("AURemoteIO::IOThread"), "Audio (keepalive, voice)")
        let summary = BatteryUsageSummary(hours: [
            hour(0, threads: ["main": 10, "com.apple.SwiftUI.AsyncRenderer": 30]),
            hour(1, threads: ["main": 5]),
        ])
        XCTAssertEqual(summary.byWork.map(\.title), ["Animations & drawing", "App & screens"])
        XCTAssertEqual(summary.byWork.last?.value, 15)
    }

    func testWithinKeepsTheHoursThatOverlapTheRange() {
        let hours = (0..<5).map { hour($0) }
        let kept = BatteryUsageSummary.within(hours, since: t0.addingTimeInterval(2.5 * 3600))
        XCTAssertEqual(kept.count, 3)
    }

    func testDurations() {
        XCTAssertEqual(BatteryUsageSummary.duration(42), "42 s")
        XCTAssertEqual(BatteryUsageSummary.duration(600), "10 min")
        XCTAssertEqual(BatteryUsageSummary.duration(3600 * 17 + 37 * 60), "17 h 37 min")
    }
}
