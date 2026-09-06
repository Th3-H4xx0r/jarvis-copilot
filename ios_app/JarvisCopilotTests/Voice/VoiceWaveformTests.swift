import XCTest
@testable import JarvisCopilot

/// The level/geometry model behind `voice_waveform.dart`'s painter (the view
/// itself is the second-wave agent's job).
final class VoiceWaveformTests: XCTestCase {

    func testListeningAndSpeakingAreTheReactiveStates() {
        XCTAssertTrue(VoiceWaveformModel.isReactive(.listening))
        XCTAssertTrue(VoiceWaveformModel.isReactive(.speaking))
        for s in [VoiceState.idle, .connecting, .thinking, .error] {
            XCTAssertFalse(VoiceWaveformModel.isReactive(s))
        }
    }

    func testReactiveEnvelopeGrowsWithAmplitudeAndHasAFloor() {
        let quiet = VoiceWaveformModel.envelope(state: .listening, amplitude: 0, t: 0)
        let mid = VoiceWaveformModel.envelope(state: .listening, amplitude: 0.25, t: 0)
        let loud = VoiceWaveformModel.envelope(state: .listening, amplitude: 1, t: 0)
        XCTAssertEqual(quiet, 0.18, accuracy: 0.0001, "a floor keeps the ribbon alive")
        XCTAssertGreaterThan(mid, quiet)
        XCTAssertGreaterThan(loud, mid)
        XCTAssertLessThanOrEqual(loud, 1.4, "clamped ceiling")
    }

    func testReactiveEnvelopeUsesASqrtCurveSoQuietSpeechStillLifts() {
        // sqrt(0.25) * 1.35 = 0.675 — a linear map would give 0.3375.
        XCTAssertEqual(VoiceWaveformModel.envelope(state: .listening, amplitude: 0.25, t: 0),
                       0.675, accuracy: 0.0001)
    }

    func testNonReactiveEnvelopeSelfOscillatesAroundABase() {
        for t in stride(from: 0.0, through: 4.0, by: 0.25) {
            let e = VoiceWaveformModel.envelope(state: .thinking, amplitude: 1.0, t: t)
            XCTAssertGreaterThanOrEqual(e, 0.16 - 0.05 - 0.0001)
            XCTAssertLessThanOrEqual(e, 0.16 + 0.05 + 0.0001)
        }
    }

    func testAmplitudeIsClampedIntoZeroToOne() {
        XCTAssertEqual(VoiceWaveformModel.envelope(state: .listening, amplitude: 9, t: 0),
                       VoiceWaveformModel.envelope(state: .listening, amplitude: 1, t: 0))
        XCTAssertEqual(VoiceWaveformModel.envelope(state: .listening, amplitude: -3, t: 0),
                       VoiceWaveformModel.envelope(state: .listening, amplitude: 0, t: 0))
    }

    func testThereAreThreeOverlaidBands() {
        XCTAssertEqual(VoiceWaveformModel.bands.count, 3)
        // Each band points at a distinct palette slot so it matches the orb.
        XCTAssertEqual(Set(VoiceWaveformModel.bands.map(\.paletteIndex)).count, 3)
    }

    func testOffsetsPinchToZeroAtBothEnds() throws {
        let band = try XCTUnwrap(VoiceWaveformModel.bands.first)
        let ys = VoiceWaveformModel.offsets(band: band, t: 1.3, env: 1.0)
        XCTAssertEqual(ys.count, VoiceWaveformModel.steps + 1)
        XCTAssertEqual(ys[0], 0, accuracy: 1e-9)
        XCTAssertEqual(ys[ys.count - 1], 0, accuracy: 1e-9)
    }

    func testOffsetsScaleLinearlyWithTheEnvelope() throws {
        let band = try XCTUnwrap(VoiceWaveformModel.bands.first)
        let a = VoiceWaveformModel.offsets(band: band, t: 0.7, env: 0.5)
        let b = VoiceWaveformModel.offsets(band: band, t: 0.7, env: 1.0)
        for i in 0..<a.count { XCTAssertEqual(b[i], a[i] * 2, accuracy: 1e-9) }
    }

    func testEveryStatePalettesFourColours() {
        for s in [VoiceState.idle, .connecting, .listening, .thinking, .speaking, .error] {
            XCTAssertEqual(s.palette.count, 4, "\(s) palette")
        }
    }

    func testStateLabelsMatchTheFlutterFsm() {
        XCTAssertEqual(VoiceState.idle.label, "Idle")
        XCTAssertEqual(VoiceState.connecting.label, "Connecting")
        XCTAssertEqual(VoiceState.listening.label, "Listening")
        XCTAssertEqual(VoiceState.thinking.label, "Thinking")
        XCTAssertEqual(VoiceState.speaking.label, "Speaking")
        XCTAssertEqual(VoiceState.error.label, "Error")
    }
}
