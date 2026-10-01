import XCTest
@testable import JarvisCopilot

/// The X5 on the R12's inputs screen: its own gesture and mode lists, nothing leaking into the R12's.
@MainActor
final class X5GestureTests: XCTestCase {

    func testEachRingOffersItsOwnModes() {
        XCTAssertEqual(RingInputMode.r12, [.jarvis, .music, .off])
        XCTAssertEqual(RingInputMode.x5, [.jarvis, .shortVideo, .music, .camera, .off])
    }

    func testEveryX5ModeMapsOntoTheTouchSurface() {
        XCTAssertTrue(X5Manager.hid(for: .jarvis) == (true, .keys))
        XCTAssertTrue(X5Manager.hid(for: .shortVideo) == (true, .shortVideo))
        XCTAssertTrue(X5Manager.hid(for: .music) == (true, .music))
        XCTAssertTrue(X5Manager.hid(for: .camera) == (true, .camera))
        XCTAssertFalse(X5Manager.hid(for: .off).enabled)
    }

    func testStoredR12ModesStillDecode() {
        XCTAssertEqual(RingInputMode(rawValue: "jarvis"), .jarvis)
        XCTAssertEqual(RingInputMode(rawValue: "music"), .music)
        XCTAssertEqual(RingInputMode(rawValue: "off"), .off)
        XCTAssertEqual(RingInputMode(rawValue: "short_videos"), .shortVideo)
    }

    /// The R12 reads its mode back by app type; the X5's modes share "off"'s, and must never win.
    func testTheR12NeverReadsBackAnX5Mode() {
        XCTAssertEqual(RingInputMode.r12.first { $0.appType == RingInputMode.off.appType }, .off)
    }

    func testTheX5InputsAreAllNineGestures() {
        XCTAssertEqual(RingInput.x5.count, 9)
        XCTAssertFalse(RingInput.x5.contains(.doublePress))
        XCTAssertFalse(RingInput.x5.contains(.shake))
    }
}
