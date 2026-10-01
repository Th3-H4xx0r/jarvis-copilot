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

    /// A ring iOS already holds (paired as a keyboard, say) doesn't advertise: it is only found as
    /// a connected peripheral offering FFF0, whatever it calls itself. It is checked on connect.
    func testAConnectedFFF0DeviceIsACandidateWhateverItsName() {
        XCTAssertTrue(X5Manager.isCandidate(name: "SmartRing", hasService: true, strict: false))
        XCTAssertTrue(X5Manager.isCandidate(name: "", hasService: true, strict: false))
        XCTAssertFalse(X5Manager.isCandidate(name: "SmartRing", hasService: true, strict: true))
        XCTAssertTrue(X5Manager.isCandidate(name: "X5_7A21", hasService: false, strict: true))
        XCTAssertFalse(X5Manager.isCandidate(name: "R12_7E04", hasService: true, strict: false))
        XCTAssertFalse(X5Manager.isCandidate(name: "Headphones", hasService: false, strict: false))
    }

    /// Review finding #10: the bathroom scale advertises FFF0 too.
    func testTheScaleIsNeverAnX5Candidate() {
        XCTAssertFalse(X5Manager.isCandidate(name: "Etekcity Smart Fitness Scale", hasService: true, strict: false))
        XCTAssertFalse(X5Manager.isCandidate(name: "ESF551", hasService: true, strict: false))
    }

    func testX5AnywhereInTheNameAsAWordCounts() {
        XCTAssertTrue(X5Protocol.isX5Name("Smart Ring X5"))
        XCTAssertTrue(X5Protocol.isX5Name("X5-Ring"))
        XCTAssertFalse(X5Protocol.isX5Name("AX5B"))
        XCTAssertFalse(X5Protocol.isX5Name("X50"))
    }

    // One 10-second hold reports 0C (~1 s), 0E (5 s) and 0F (10 s): only the longest bound hold runs.
    func testALongHoldRunsOnlyTheLongestHoldThatHasAnAction() {
        var gate = X5HoldGate()
        let t0 = Date(timeIntervalSince1970: 0)
        let bound: (RingInput) -> Bool = { $0 == .longPress || $0 == .holdFiveSeconds }
        XCTAssertEqual(gate.arrive(.longPress, at: t0, bound: bound), [.wait(.longPress, until: t0.addingTimeInterval(X5HoldGate.toFive))])
        XCTAssertEqual(gate.arrive(.hold5s, at: t0.addingTimeInterval(4), bound: bound), [.cancel(.longPress), .run(.holdFiveSeconds)])
        XCTAssertNil(gate.due(at: t0.addingTimeInterval(10)))
    }

    func testALongPressReleasedEarlyRunsWhenItsWaitIsOver() {
        var gate = X5HoldGate()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = gate.arrive(.longPress, at: t0, bound: { _ in true })
        XCTAssertNil(gate.due(at: t0.addingTimeInterval(1)))
        XCTAssertEqual(gate.due(at: t0.addingTimeInterval(X5HoldGate.toFive)), .longPress)
        XCTAssertNil(gate.due(at: t0.addingTimeInterval(9)))
    }

    func testWithNoLongerHoldBoundALongPressRunsAtOnce() {
        var gate = X5HoldGate()
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(gate.arrive(.longPress, at: now, bound: { $0 == .longPress }), [.run(.longPress)])
        XCTAssertEqual(gate.arrive(.click, at: now, bound: { _ in true }), [.run(.tap)])
    }

    func testATenSecondHoldCancelsTheFiveSecondOne() {
        var gate = X5HoldGate()
        let t0 = Date(timeIntervalSince1970: 0)
        let all: (RingInput) -> Bool = { _ in true }
        _ = gate.arrive(.longPress, at: t0, bound: all)
        _ = gate.arrive(.hold5s, at: t0.addingTimeInterval(4), bound: all)
        XCTAssertEqual(gate.arrive(.hold10s, at: t0.addingTimeInterval(9), bound: all), [.cancel(.holdFiveSeconds), .run(.holdTenSeconds)])
    }

    func testTheX5InputsAreAllNineGestures() {
        XCTAssertEqual(RingInput.x5.count, 9)
        XCTAssertFalse(RingInput.x5.contains(.doublePress))
        XCTAssertFalse(RingInput.x5.contains(.shake))
    }
}
