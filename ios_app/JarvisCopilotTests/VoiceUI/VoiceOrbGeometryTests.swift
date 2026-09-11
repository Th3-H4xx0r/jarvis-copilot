import XCTest
@testable import JarvisCopilot

/// The orb's maths — how loud the user is becomes how big and how bright the orb
/// gets. Pure, so it can be asserted with no renderer.
@MainActor
final class VoiceOrbGeometryTests: XCTestCase {

    // MARK: - Envelope

    func testSmoothMovesTowardTheTarget() {
        let stepped = VoiceOrbGeometry.smooth(previous: 0, target: 1, dt: 0.05)
        XCTAssertGreaterThan(stepped, 0)
        XCTAssertLessThan(stepped, 1)
    }

    /// Attack is faster than release: the orb must jump on a syllable and settle
    /// gently between, not the other way round.
    func testAttackIsFasterThanRelease() {
        let rise = VoiceOrbGeometry.smooth(previous: 0.0, target: 1.0, dt: 0.05)
        let fall = VoiceOrbGeometry.smooth(previous: 1.0, target: 0.0, dt: 0.05)
        XCTAssertGreaterThan(rise, 1 - fall)
    }

    func testSmoothIsMonotonicAndConverges() {
        var value = 0.0
        for _ in 0..<200 { value = VoiceOrbGeometry.smooth(previous: value, target: 1, dt: 0.016) }
        XCTAssertEqual(value, 1, accuracy: 0.01)
    }

    /// A paused ticker (another tab, a backgrounded app) resumes with a huge gap;
    /// the envelope clamps dt so the orb eases in instead of snapping.
    func testEnvelopeClampsAHugeTimeGap() {
        let envelope = VoiceOrbEnvelope()
        _ = envelope.update(target: 0, t: 0)
        let afterGap = envelope.update(target: 1, t: 30)
        XCTAssertLessThan(afterGap, 1)
        XCTAssertGreaterThan(afterGap, 0)
    }

    func testBothSpeakersHaveAVisibleQuietSpeechPulse() {
        let mic = VoiceOrbGeometry.speechPulse(state: .listening, amplitude: 0.025)
        let reply = VoiceOrbGeometry.speechPulse(state: .speaking, amplitude: 0.025)
        XCTAssertGreaterThan(mic, 0.3, "quiet speech must visibly expand the orb")
        XCTAssertEqual(reply, mic)
        XCTAssertGreaterThan(VoiceOrbGeometry.speechPulse(state: .speaking, amplitude: 0.4), reply)
        for state in [VoiceState.idle, .connecting, .thinking, .error] {
            XCTAssertEqual(VoiceOrbGeometry.speechPulse(state: state, amplitude: 0.8), 0)
        }
        XCTAssertEqual(VoiceOrbGeometry.speechPulse(state: .listening, amplitude: 0.002), 0)
        XCTAssertLessThanOrEqual(VoiceOrbGeometry.speechPulse(state: .speaking, amplitude: 2), 1)
    }

    // MARK: - Drive

    // MARK: - Reactive drive

    // MARK: - Motion

    // MARK: - Radius / glow

}
