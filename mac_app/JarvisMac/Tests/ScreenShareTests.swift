import CoreGraphics
import XCTest
@testable import Jarvis

/// Mac screen sharing: the viewer's normalised pointer lands on the right spot of
/// the shared display, keys map to the right codes, and the stream size stays ≤1080p.
final class ScreenShareTests: XCTestCase {

    func testNormalisedPointsMapOntoTheDisplay() {
        let inj = InputInjector(bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(inj.point(x: 0, y: 0), CGPoint(x: 1440, y: 0))
        XCTAssertEqual(inj.point(x: 0.5, y: 0.5), CGPoint(x: 2400, y: 540))
        XCTAssertEqual(inj.point(x: 1, y: 1), CGPoint(x: 3360, y: 1080))
        // Out of range is clamped onto the display.
        XCTAssertEqual(inj.point(x: -1, y: 2), CGPoint(x: 1440, y: 1080))
    }

    func testKeyNamesFromBrowsersAndTheContractMap() {
        XCTAssertEqual(InputInjector.keyCode("Return"), 36)
        XCTAssertEqual(InputInjector.keyCode("Enter"), 36)
        XCTAssertEqual(InputInjector.keyCode("Backspace"), 51)
        XCTAssertEqual(InputInjector.keyCode("ArrowLeft"), 123)
        XCTAssertEqual(InputInjector.keyCode("Escape"), 53)
        XCTAssertEqual(InputInjector.keyCode("c"), 8)
        XCTAssertEqual(InputInjector.keyCode("C"), 8)
        XCTAssertNil(InputInjector.keyCode("é"))
        XCTAssertEqual(InputInjector.flags(["cmd", "shift"]), [.maskCommand, .maskShift])
        XCTAssertEqual(InputInjector.flags(["alt", "ctrl", "nope"]), [.maskAlternate, .maskControl])
    }

    func testStreamSizeFitsInto1080pWithEvenSides() {
        XCTAssertEqual(FramePipeline.outputSize(pixels: CGSize(width: 3456, height: 2234)),
                       CGSize(width: 1670, height: 1080))
        XCTAssertEqual(FramePipeline.outputSize(pixels: CGSize(width: 1280, height: 800)),
                       CGSize(width: 1280, height: 800))
        XCTAssertEqual(FramePipeline.outputSize(pixels: CGSize(width: 5120, height: 1440)),
                       CGSize(width: 1920, height: 540))
    }
}
