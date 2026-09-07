import XCTest
@testable import JarvisCopilot

final class StopwatchCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStartsStoppedAtZero() {
        let sw = StopwatchCore()
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.elapsed(at: t0), 0)
    }

    func testElapsedGrowsWhileRunningAndFreezesWhenStopped() {
        var sw = StopwatchCore()
        sw.start(at: t0)
        XCTAssertTrue(sw.isRunning)
        XCTAssertEqual(sw.elapsed(at: t0.addingTimeInterval(12.5)), 12.5)
        sw.stop(at: t0.addingTimeInterval(20))
        XCTAssertFalse(sw.isRunning)
        XCTAssertEqual(sw.elapsed(at: t0.addingTimeInterval(500)), 20)
    }

    func testResumingAccumulatesAcrossSegments() {
        var sw = StopwatchCore()
        sw.start(at: t0)
        sw.stop(at: t0.addingTimeInterval(10))
        sw.start(at: t0.addingTimeInterval(100))
        XCTAssertEqual(sw.elapsed(at: t0.addingTimeInterval(105)), 15)
    }

    func testStartWhileRunningAndStopWhileStoppedAreNoOps() {
        var sw = StopwatchCore()
        sw.stop(at: t0)
        XCTAssertEqual(sw.elapsed(at: t0), 0)
        sw.start(at: t0)
        sw.start(at: t0.addingTimeInterval(5))   // must not restart the segment
        XCTAssertEqual(sw.elapsed(at: t0.addingTimeInterval(10)), 10)
    }

    func testLapsMeasureFromThePreviousLap() {
        var sw = StopwatchCore()
        sw.start(at: t0)
        XCTAssertEqual(sw.lap(at: t0.addingTimeInterval(30)), 30)
        XCTAssertEqual(sw.lap(at: t0.addingTimeInterval(45)), 15)
        XCTAssertEqual(sw.laps, [30, 15])
    }

    func testLapsAreCapped() {
        var sw = StopwatchCore()
        sw.start(at: t0)
        for i in 1...(StopwatchCore.maxLaps + 5) { sw.lap(at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(sw.laps.count, StopwatchCore.maxLaps)
    }

    func testResetClearsEverything() {
        var sw = StopwatchCore()
        sw.start(at: t0)
        sw.lap(at: t0.addingTimeInterval(3))
        sw.reset()
        XCTAssertEqual(sw, StopwatchCore())
    }

    func testFormatting() {
        XCTAssertEqual(StopwatchCore.format(0), "00:00.0")
        XCTAssertEqual(StopwatchCore.format(83.25), "01:23.2")   // %04.1f rounds half-even-ish; .25 → .2
        XCTAssertEqual(StopwatchCore.format(3723.4), "1:02:03.4")
        XCTAssertEqual(StopwatchCore.format(-5), "00:00.0")
    }
}
