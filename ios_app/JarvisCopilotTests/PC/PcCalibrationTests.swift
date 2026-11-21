import XCTest
@testable import JarvisCopilot

/// Calibration turns "this range is that fan, starting here, running this way" into the LED map.
final class PcCalibrationTests: XCTestCase {
    private func cal() -> PcCalibration {
        PcCalibration(zones: [.init(controller: 0, zone: 0, resizable: true, leds: 40),
                              .init(controller: 0, zone: 1, resizable: false, leds: 1),
                              .init(controller: 0, zone: 2, resizable: true, leds: 40)])
    }

    func testChainedFansBecomeConsecutiveSegments() {
        var c = cal()
        c.setSize(lastLit: 47)
        XCTAssertEqual(c.size, 48)
        c.addSegment(end: 15, part: .bottom, index: 0, ringStartDeg: 90, clockwise: true)
        c.addSegment(end: 31, part: .bottom, index: 1, ringStartDeg: 90, clockwise: true)
        XCTAssertEqual(c.cursor, 32)
        c.addSegment(end: 47, part: .bottom, index: 2, ringStartDeg: 270, clockwise: false)
        XCTAssertEqual(c.zoneIndex, 1)                     // zone 0 finished
        let m = c.map()
        XCTAssertEqual(m.zones.first, PcZone(controller: 0, zone: 0, leds: 48))
        XCTAssertEqual(m.segments.map(\.start), [0, 16, 32])
        XCTAssertEqual(m.segments.map(\.count), [16, 16, 16])
        XCTAssertEqual(m.segments.last?.clockwise, false)
    }

    func testNothingLitSkipsTheZone() {
        var c = cal()
        c.setSize(lastLit: 15)
        c.addSegment(end: 15, part: .top, index: 0, ringStartDeg: 0, clockwise: true)
        c.skipZone()                                       // the 12 V header: nothing lit
        XCTAssertEqual(c.zoneIndex, 2)
        XCTAssertFalse(c.map().zones.contains { $0.zone == 1 })
    }

    func testFixedSizeZoneUsesItsReportedLEDs() {
        var c = cal()
        c.setSize(lastLit: 15)
        c.addSegment(end: 15, part: .top, index: 0, ringStartDeg: 0, clockwise: true)
        XCTAssertEqual(c.size, 1)                          // zone 1 can't be resized: 1 LED
        c.addSegment(end: 0, part: .cooler, index: 0, ringStartDeg: nil, clockwise: nil)
        XCTAssertEqual(c.map().segments.last?.part, "cooler")
    }

    func testSharedRangeRecordsTheOtherParts() {
        var c = cal()
        c.setSize(lastLit: 9)
        c.addSegment(end: 9, part: .strip, index: 0, ringStartDeg: nil, clockwise: nil, from: "front", also: [.cooler])
        XCTAssertEqual(c.map().segments.first?.also, ["cooler"])
        XCTAssertEqual(c.map().segments.first?.from, "front")
    }

    func testDoneAfterTheLastZoneAndEveryPartCoveredIsReported() {
        var c = PcCalibration(zones: [.init(controller: 0, zone: 0, resizable: false, leds: 16)])
        c.addSegment(end: 15, part: .top, index: 0, ringStartDeg: 0, clockwise: true)
        XCTAssertTrue(c.done)
        XCTAssertEqual(c.missingParts, [.rear, .bottom, .cooler, .strip])
    }

    func testTapAngleSnapsToTheNearestSocket() {
        XCTAssertEqual(PcCalibration.snap(degrees: 100, sockets: 16), 90)
        XCTAssertEqual(PcCalibration.snap(degrees: 350, sockets: 16), 0)
        XCTAssertEqual(PcCalibration.snap(degrees: -20, sockets: 16), 337.5)
    }
}
