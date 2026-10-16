import XCTest
@testable import JarvisCopilot

/// The CarPlay Talk widget: one tap talks, a second stops, and what it shows.
final class CarTalkTests: XCTestCase {

    func testToggleStartsWhenIdleAndStopsWhenActive() {
        XCTAssertEqual(CarTalkBridge.action(sessionActive: false), .start)
        XCTAssertEqual(CarTalkBridge.action(sessionActive: true), .stop,
                       "a second tap stops — connecting, listening, thinking or speaking")
    }

    func testStaleSnapshotShowsIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stuck = CarTalkSnapshot(state: "listening", line: "how hot",
                                    updatedAt: now.addingTimeInterval(-(CarTalkSnapshot.staleAfter + 1)))
        let shown = stuck.shown(now: now)
        XCTAssertEqual(shown.state, "idle", "a killed app must not leave the widget saying Listening")
        XCTAssertEqual(shown.line, "")
    }

    func testFreshSnapshotKept() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let live = CarTalkSnapshot(state: "speaking", line: "It's 72 degrees.",
                                   updatedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(live.shown(now: now), live)
    }

    func testAnOldIdleReplyStillClears() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = CarTalkSnapshot(state: "idle", line: "It's 72 degrees.",
                                  updatedAt: now.addingTimeInterval(-(CarTalkSnapshot.staleAfter + 1)))
        XCTAssertEqual(old.shown(now: now).line, "", "the reply leaves with its 2 minutes")
    }

    func testSnapshotRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CarTalkTests-\(UUID().uuidString)"))
        XCTAssertEqual(CarTalkSnapshot.load(defaults).state, "idle", "nothing saved reads as idle")
        let snap = CarTalkSnapshot(state: "thinking", line: "how hot is it",
                                   updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        snap.save(defaults)
        XCTAssertEqual(CarTalkSnapshot.load(defaults), snap)
    }

    func testAudioRefusalsAreSaidInWords() {
        func reason(_ code: Int) -> String? {
            VoiceStore.audioSessionReason(NSError(domain: NSOSStatusErrorDomain, code: code))
        }
        XCTAssertEqual(reason(561145187), "iOS won't start the mic while Jarvis is in the background (!rec)")
        XCTAssertEqual(reason(561017449), "another app has the mic, like a call or Siri (!pri)")
        XCTAssertNotNil(reason(1836282486), "any audio-system code is named")
        XCTAssertNil(VoiceStore.audioSessionReason(URLError(.notConnectedToInternet)),
                     "network failures keep their own message")
    }

    func testEarconsFollowTheTurn() {
        XCTAssertEqual(VoiceEarcon.forTransition(from: .connecting, to: .listening), .listening)
        XCTAssertEqual(VoiceEarcon.forTransition(from: .speaking, to: .listening), .listening)
        XCTAssertEqual(VoiceEarcon.forTransition(from: .listening, to: .thinking), .thinking)
        XCTAssertNil(VoiceEarcon.forTransition(from: .thinking, to: .speaking))
        XCTAssertNil(VoiceEarcon.forTransition(from: .listening, to: .idle), "Stop is not a question")
    }

    func testEarconToneIsAPlayableWav() {
        let wav = ToneEarconPlayer.wav([(hz: 660, ms: 70), (hz: 990, ms: 110)], rate: 24000)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(wav.count, 44 + (24000 * 180 / 1000) * 2, "16-bit mono samples after the header")
    }
}
