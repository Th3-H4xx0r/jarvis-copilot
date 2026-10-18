import AVFoundation
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

    /// His picks (2026-10-18, after two rounds of synthesised tones he found annoying): an AI
    /// notification chime from Pixabay, cut to its first notes for "listening" (L3) and the same,
    /// shorter and lower, for "done" (D3).
    func testTheEarconsAreHisShortChimes() throws {
        let listening = try AVAudioPlayer(data: VoiceEarconSounds.data(for: .listening))
        let done = try AVAudioPlayer(data: VoiceEarconSounds.data(for: .thinking))
        XCTAssertEqual(listening.duration, 0.32, accuracy: 0.03)
        XCTAssertEqual(done.duration, 0.175, accuracy: 0.03)
    }

    /// The mic ignores itself while a sound plays: both stay short and end in silence.
    func testEachEarconEndsInSilence() {
        for earcon in [VoiceEarcon.listening, .thinking] {
            let samples = Self.samples(VoiceEarconSounds.data(for: earcon))
            XCTAssertFalse(samples.isEmpty)
            XCTAssertLessThan(abs(Int(samples.last ?? 1)), 400, "\(earcon) fades out")
        }
    }

    private static func samples(_ wav: Data) -> [Int16] {
        wav.dropFirst(44).withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self)) }
        }
    }
}
