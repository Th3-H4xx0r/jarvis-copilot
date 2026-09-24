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

@MainActor
final class MacLivePresentationTests: XCTestCase {
    private func turn(_ seq: Int, id: String?, name: String? = nil) -> LiveTimelineItem {
        var line = LiveSegment()
        line.seq = seq
        line.speakerID = id
        line.speakerName = name
        line.text = "words"
        return .turn(LiveTurn(lines: [line]))
    }

    func testSpeakersAreNumberedInTheOrderTheyFirstSpeak() {
        let labels = MacLiveSpeakers.labels([turn(1, id: "spk-4163"), turn(2, id: "spk-8162"), turn(3, id: "spk-4163")])
        XCTAssertEqual(labels.values.map(\.name).sorted(), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(labels.values.first { $0.name == "Speaker 1" }?.index, 0)
    }

    func testANameGivenLaterStillNamesTheSpeaker() {
        let labels = MacLiveSpeakers.labels([turn(1, id: "spk-1"), turn(2, id: "spk-1", name: "Sam")])
        XCTAssertEqual(labels.values.map(\.name), ["Sam"])
    }

    func testOnlyAnotherLanguageGetsABadge() {
        XCTAssertNil(MacLiveLanguage.badge("en", primary: "en-US"))
        XCTAssertNil(MacLiveLanguage.badge("", primary: "en-US"))
        XCTAssertEqual(MacLiveLanguage.badge("te", primary: "en-US")?.lowercased(), "telugu")
    }
}
