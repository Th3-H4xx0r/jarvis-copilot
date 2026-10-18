import XCTest
@testable import JarvisCopilot

/// The CarPlay Talk widget: its orb, its sounds, and how a refusal reads.
final class CarTalkTests: XCTestCase {

    /// iOS refuses a backgrounded app the mic (`!int`), so the orb opens Jarvis on
    /// the car's screen already listening — for one answer, like the old button.
    func testTheOrbOpensJarvisOnTheCarListeningForOneAnswer() throws {
        XCTAssertTrue(CarPlayLinks.isVoice(CarTalkLink.url))
        XCTAssertTrue(CarPlayLinks.wantsOneAnswer(CarTalkLink.url))
        let voiceWidget = try XCTUnwrap(URL(string: "jarviscopilot://voice"))
        XCTAssertTrue(CarPlayLinks.isVoice(voiceWidget))
        XCTAssertFalse(CarPlayLinks.wantsOneAnswer(voiceWidget), "the JARVIS Voice widget keeps the conversation going")
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
