import XCTest
@testable import JarvisCopilot

/// OpenRGB-style calibration: each connector's LED count from a slider, then runs of LEDs painted onto parts.
final class PcCalibrationTests: XCTestCase {
    private func board() -> PcCalibrationBoard {
        PcCalibrationBoard(connectors: [
            .init(controller: 0, zone: 0, name: "RGB LED 1 Header", max: 1, resizable: false, leds: 1),
            .init(controller: 0, zone: 2, name: "Addressable Header 2", max: 100, resizable: true, leds: 80),
            .init(controller: 0, zone: 3, name: "Addressable Header 3/Audio", max: 100, resizable: true, leds: 80)])
    }

    func testTheSliderSetsTheCountWithinTheConnectorsLimits() {
        var b = board()
        b.setLEDs(2, 160)
        XCTAssertEqual(b.connectors[2].leds, 100)
        b.setLEDs(2, 16)
        XCTAssertEqual(b.connectors[2].leds, 16)
        b.setLEDs(0, 5)
        XCTAssertEqual(b.connectors[0].leds, 1)            // a fixed connector keeps its size
    }

    func testPaintingARunAssignsItToAPart() {
        var b = board()
        b.setLEDs(1, 40)
        b.assign(1, 0...29, part: .strip, index: 0)
        b.assign(1, 30...39, part: .cooler, index: 0)
        XCTAssertEqual(b.part(1, led: 12), .strip)
        XCTAssertEqual(b.part(1, led: 35), .cooler)
        let m = b.map()
        XCTAssertEqual(m.segments.map(\.part), ["strip", "cooler"])
        XCTAssertEqual(m.segments.map(\.start), [0, 30])
        XCTAssertEqual(m.segments.map(\.count), [30, 10])
    }

    func testRepaintingReplacesWhatWasThere() {
        var b = board()
        b.setLEDs(1, 40)
        b.assign(1, 0...39, part: .strip, index: 0)
        b.assign(1, 30...39, part: .cooler, index: 0)
        XCTAssertEqual(b.map().segments.first { $0.part == "strip" }?.count, 30)
    }

    func testAMirroredHubIsOneRunSharedByEveryFan() {
        var b = board()
        b.setLEDs(2, 16)
        b.assign(2, 0...15, part: .bottom, index: 0, also: [.top, .rear])
        let seg = b.map().segments.first!
        XCTAssertEqual(seg.also, ["top", "rear"])
        XCTAssertEqual(b.missingParts, [.cooler, .strip])
    }

    func testShrinkingDropsPaintBeyondTheEnd() {
        var b = board()
        b.setLEDs(1, 40)
        b.assign(1, 30...39, part: .cooler, index: 0)
        b.setLEDs(1, 20)
        XCTAssertNil(b.part(1, led: 35))
        XCTAssertTrue(b.map().segments.isEmpty)
    }

    func testEmptyConnectorsAndColourOrderInTheMap() {
        var b = board()
        b.setLEDs(2, 16)
        b.setOrder(2, "grb")
        b.assign(2, 0...15, part: .bottom, index: 0)
        let m = b.map()
        XCTAssertEqual(m.zones, [PcZone(controller: 0, zone: 3, leds: 16, order: "grb")])   // unpainted connectors left out
    }

    func testADrawnLineGoesIntoTheMap() {
        var b = board()
        b.setLEDs(1, 40)
        b.assign(1, 0...29, part: .strip, index: 0, line: [[0, 0.5, 1.4], [2, 0.5, 1.4]])
        XCTAssertEqual(b.map().segments.first?.line, [[0, 0.5, 1.4], [2, 0.5, 1.4]])
    }

    func testPlacingOnTheModelPaintsTheFirstFanAndMirrorsTheRest() {
        var b = board()
        b.setLEDs(2, 16)
        b.place(2, 0...15, fans: [PcLedKey(part: .bottom, index: 1, led: 0), PcLedKey(part: .top, index: 0, led: 3),
                                 PcLedKey(part: .bottom, index: 0, led: 0)], line: nil)
        let seg = b.map().segments.first
        XCTAssertEqual(seg?.part, "bottom")
        XCTAssertEqual(seg?.index, 1)
        XCTAssertEqual(seg?.also, ["top"])
    }

    func testPlacingADrawnLineMakesTheStrip() {
        var b = board()
        b.setLEDs(1, 40)
        b.place(1, 8...30, fans: [], line: [[0, 0.5, 1.4], [2, 0.5, 1.4]])
        let seg = b.map().segments.first
        XCTAssertEqual(seg?.part, "strip")
        XCTAssertEqual(seg?.start, 8)
        XCTAssertEqual(seg?.count, 23)
        XCTAssertEqual(seg?.line, [[0, 0.5, 1.4], [2, 0.5, 1.4]])
    }

    func testTapAngleSnapsToTheNearestSocket() {
        XCTAssertEqual(PcCalibration.snap(degrees: 100, sockets: 16), 90)
    }
}
