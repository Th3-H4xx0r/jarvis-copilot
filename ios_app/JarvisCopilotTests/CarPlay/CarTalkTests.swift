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
        let wav = ToneEarconPlayer.wav(ToneEarconPlayer.Glide(from: 587, to: 880, glideMs: 170, ms: 260), rate: 24000)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(wav.count, 44 + (24000 * 260 / 1000) * 2, "16-bit mono samples after the header")
    }

    /// 2026-10-18 his ask: "less annoying … more like the Gemini or Siri one … more
    /// professional" — one soft glide each, up for "go ahead", down for "got it".
    func testEachEarconIsOneShortGlideUpForListeningDownForDone() {
        let listening = ToneEarconPlayer.sound(.listening)
        let done = ToneEarconPlayer.sound(.thinking)
        XCTAssertLessThan(listening.from, listening.to)
        XCTAssertGreaterThan(done.from, done.to)
        XCTAssertLessThanOrEqual(listening.ms, 300)
        XCTAssertLessThanOrEqual(done.ms, 300)
    }

    /// No click at either end, and never loud.
    func testAnEarconStartsAndEndsInSilenceAndStaysSoft() {
        for earcon in [VoiceEarcon.listening, .thinking] {
            let samples = Self.samples(ToneEarconPlayer.wav(ToneEarconPlayer.sound(earcon)))
            XCTAssertLessThan(abs(Int(samples.first ?? 1)), 200, "\(earcon) starts in silence")
            XCTAssertLessThan(abs(Int(samples.last ?? 1)), 200, "\(earcon) ends in silence")
            let peak = samples.map { abs(Double($0)) / Double(Int16.max) }.max() ?? 1
            XCTAssertLessThan(peak, 0.2, "\(earcon) stays soft")
            XCTAssertGreaterThan(peak, 0.05, "\(earcon) is still heard")
        }
    }

    private static func samples(_ wav: Data) -> [Int16] {
        wav.dropFirst(44).withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self)) }
        }
    }
}
