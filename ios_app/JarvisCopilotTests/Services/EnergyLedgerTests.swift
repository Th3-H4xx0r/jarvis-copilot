import XCTest
@testable import JarvisCopilot

/// The hour-by-hour ledger behind Settings → Battery usage: time and CPU go to the state that
/// held while they were spent.
final class EnergyLedgerTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        var cpu = 100.0
        func advance(_ seconds: Double, cpu used: Double) {
            now = now.addingTimeInterval(seconds)
            cpu += used
        }
    }

    private var clock = Clock()
    private var file: URL!

    override func setUp() {
        clock = Clock()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("energy-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func ledger(file: URL? = nil) -> EnergyLedger {
        let clock = self.clock
        return EnergyLedger(cpu: { clock.cpu }, now: { clock.now }, file: file)
    }

    func testOnScreenTimeGoesToTheTabAndTheScreenShowing() {
        let l = ledger()
        l.setNetwork("wifi")
        l.setTab("health")
        l.screenAppeared("Sleep")
        clock.advance(600, cpu: 30)
        let hour = l.closeHour(threads: [:], battery: nil)
        XCTAssertEqual(hour.seconds("foreground"), 600, accuracy: 0.01)
        XCTAssertEqual(hour.cpu("foreground"), 30, accuracy: 0.01)
        XCTAssertEqual(hour.cpu("tab.health"), 30, accuracy: 0.01)
        XCTAssertEqual(hour.cpu("where.health|Sleep"), 30, accuracy: 0.01)
        XCTAssertEqual(hour.seconds("wifi"), 600, accuracy: 0.01)
        XCTAssertEqual(hour.seconds("background"), 0)
    }

    func testBackgroundTimeIsSplitByWhatHeldWhileItPassed() {
        let l = ledger()
        l.setNetwork("cellular")
        l.set(.keepalive, true)
        l.set(.foreground, false)
        clock.advance(1800, cpu: 5)
        l.set(.keepalive, false)
        clock.advance(1800, cpu: 1)
        let hour = l.closeHour(threads: ["main": 4], battery: nil)
        XCTAssertEqual(hour.seconds("background"), 3600, accuracy: 0.01)
        XCTAssertEqual(hour.seconds("bg.keepalive"), 1800, accuracy: 0.01)
        XCTAssertEqual(hour.cpu("bg.keepalive"), 5, accuracy: 0.01)
        XCTAssertEqual(hour.seconds("bg.cellular"), 3600, accuracy: 0.01)
        XCTAssertNil(hour.seconds["where.app|"], "no place on screen while in a pocket")
        XCTAssertEqual(hour.threads["main"], 4)
    }

    func testTheNextHourStartsFromTheBatteryTheLastOneEndedOn() {
        let l = ledger()
        clock.advance(3600, cpu: 0)
        let first = l.closeHour(threads: [:], battery: 0.8)
        XCTAssertEqual(first.batteryEnd, 0.8)
        clock.advance(3600, cpu: 0)
        let second = l.closeHour(threads: [:], battery: 0.77)
        XCTAssertEqual(second.batteryStart, 0.8)
        XCTAssertEqual(second.drained ?? 0, 3, accuracy: 0.001)
    }

    func testAnHourOnTheChargerHasNoDrain() {
        let l = ledger()
        clock.advance(10, cpu: 0)
        l.closeHour(threads: [:], battery: 0.5)
        l.set(.charging, true)
        clock.advance(3600, cpu: 0)
        XCTAssertNil(l.closeHour(threads: [:], battery: 0.45).drained)
    }

    func testRequestsAreCountedByFeatureWithTheBackgroundShare() {
        let l = ledger()
        l.request(path: "/api/integrations/jarvis-health/health/history", bytes: 1000, background: true)
        l.request(path: "/api/integrations/jarvis-health/health/history", bytes: 500, background: false)
        l.request(path: "/api/coding/agents/sessions", bytes: 10, background: true)
        let hour = l.closeHour(threads: [:], battery: nil)
        XCTAssertEqual(hour.count("net.Health history"), 2)
        XCTAssertEqual(hour.count("net.bg.Health history"), 1)
        XCTAssertEqual(hour.count("bytes.Health history"), 1500)
        XCTAssertEqual(hour.count("net.Coding agents"), 1)
    }

    func testLinkedWearablesAreTimedWhileTheyHoldALink() {
        let l = ledger()
        l.set(.foreground, false)
        l.setLinks(["E910 band"])
        clock.advance(1200, cpu: 1)
        l.setLinks([])
        clock.advance(600, cpu: 0)
        let hour = l.closeHour(threads: [:], battery: nil)
        XCTAssertEqual(hour.seconds("link.E910 band"), 1200, accuracy: 0.01)
        XCTAssertEqual(hour.seconds("bg.link.E910 band"), 1200, accuracy: 0.01)
        let bluetooth = BatteryUsageSummary(hours: [hour]).bluetooth
        XCTAssertEqual(bluetooth.map(\.title), ["E910 band"])
        XCTAssertEqual(bluetooth.first?.detail, "20 min in the background")
    }

    func testFeatureNames() {
        XCTAssertEqual(EnergyLedger.feature(for: "/api/integrations/x/health/day"), "Health uploads")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/sessions"), "Chat")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/session"), "Chat")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/devices/mobile/poll"), "Commands queue")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/devices/mobile/energy"), "Battery reports")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/dashcam/clips"), "Dashcam")
        XCTAssertEqual(EnergyLedger.feature(for: "/api/notes/list"), "Notes")
    }

    func testTheLastProcessesHoursSurviveARelaunch() {
        let first = ledger(file: file)
        clock.advance(3600, cpu: 20)
        first.closeHour(threads: [:], battery: 0.9)
        clock.advance(900, cpu: 3)
        first.set(.foreground, false)          // saves the unfinished hour
        let second = ledger(file: file)
        let hours = second.timeline()
        XCTAssertEqual(hours.count, 2, "the closed hour and the unfinished one, closed where it was saved")
        XCTAssertEqual(hours[0].batteryEnd, 0.9)
        XCTAssertEqual(hours[1].wall, 900, accuracy: 0.01)
    }

    func testScreenSpansRecordEachStretchOnScreen() {
        let l = ledger()
        clock.advance(120, cpu: 0)
        l.set(.foreground, false)
        clock.advance(600, cpu: 0)
        l.set(.foreground, true)
        clock.advance(60, cpu: 0)
        let spans = l.screenSpans()
        XCTAssertEqual(spans.count, 2, "one finished, one running")
        XCTAssertEqual(spans[0].end.timeIntervalSince(spans[0].start), 120, accuracy: 0.01)
        XCTAssertEqual(spans[1].end.timeIntervalSince(spans[1].start), 60, accuracy: 0.01)
    }
}
