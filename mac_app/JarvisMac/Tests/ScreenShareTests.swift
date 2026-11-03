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

    func testPhysicalCodesWinForShortcutsAndDeleteMeansBackspaceWithoutOne() {
        // ⌥F on a Mac browser: key "ƒ", code "KeyF" → F's key code.
        XCTAssertEqual(InputInjector.keyCode("ƒ", code: "KeyF", shortcut: true), 3)
        // ⌘⇧[ : key "{" has no key; the code does.
        XCTAssertEqual(InputInjector.keyCode("{", code: "BracketLeft", shortcut: true), 33)
        XCTAssertEqual(InputInjector.keyCode("!", code: "Digit1", shortcut: true), 18)
        // The iPhone's ⌫ sends a bare "Delete": backspace.
        XCTAssertEqual(InputInjector.keyCode("Delete", code: "", shortcut: false), 51)
        // A PC's Del key: forward delete, by name or by code.
        XCTAssertEqual(InputInjector.keyCode("ForwardDelete", code: "", shortcut: false), 117)
        XCTAssertEqual(InputInjector.keyCode("ForwardDelete", code: "Delete", shortcut: false), 117)
        XCTAssertEqual(InputInjector.keyCode("Backspace", code: "Backspace", shortcut: false), 51)
        // No modifier and no code: the name as before.
        XCTAssertEqual(InputInjector.keyCode("c", code: "", shortcut: true), 8)
        XCTAssertEqual(InputInjector.physicalKeyCode("F5"), 96)
        XCTAssertNil(InputInjector.physicalKeyCode("MediaPlayPause"))
    }

    func testBannerSaysHowManyWatchAndWhetherItRecords() {
        XCTAssertEqual(ShareBannerDetail.text(viewers: 0, recording: true), "recording, no one watching")
        XCTAssertEqual(ShareBannerDetail.text(viewers: 2, recording: false), "2 watching")
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
