import XCTest
@testable import JarvisVoiceUI

/// Live on the Mac runs the phone's store; these pin the few places it must
/// differ, so the server sees a Mac and the picker offers what a Mac has.
@MainActor
final class MacLiveTests: XCTestCase {
    func testHelloNamesAMac() {
        XCTAssertEqual(LiveHello.deviceKind, "mac")
    }

    func testTheDefaultInputIsTheFirstSource() {
        let sources = LiveCaptureSources.all()
        XCTAssertEqual(sources.first?.kind, .automatic)
        XCTAssertFalse(sources.contains { $0.kind == .wearable })
    }

    func testElapsedReadsLikeAClock() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(MacLivePanel.elapsed(from: start, to: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(MacLivePanel.elapsed(from: start, to: start.addingTimeInterval(3725)), "1:02:05")
    }
}
