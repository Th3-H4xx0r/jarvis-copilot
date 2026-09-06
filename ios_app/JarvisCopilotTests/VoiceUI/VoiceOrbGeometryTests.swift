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

    // MARK: - Drive

    /// Only the user's own voice drives the orb: pulsing at the assistant's own
    /// playback reads as feedback.
    func testOnlyListeningTakesTheMicAmplitude() {
        XCTAssertEqual(VoiceOrbGeometry.micDrive(state: .listening, amplitude: 0.7), 0.7, accuracy: 1e-9)
        for state in [VoiceState.idle, .connecting, .thinking, .speaking, .error] {
            XCTAssertEqual(VoiceOrbGeometry.micDrive(state: state, amplitude: 0.7), 0)
        }
    }

    func testMicDriveClampsOutOfRangeAmplitudes() {
        XCTAssertEqual(VoiceOrbGeometry.micDrive(state: .listening, amplitude: 4), 1)
        XCTAssertEqual(VoiceOrbGeometry.micDrive(state: .listening, amplitude: -2), 0)
    }

    // MARK: - Reactive drive

    func testListeningReactiveRisesWithAmplitudeAndSaturates() {
        let quiet = VoiceOrbGeometry.reactive(state: .listening, amplitude: 0.05, t: 0)
        let loud = VoiceOrbGeometry.reactive(state: .listening, amplitude: 0.8, t: 0)
        XCTAssertGreaterThan(loud, quiet)
        // Even quiet speech has to give a visible swell — mic level reads low.
        XCTAssertGreaterThan(quiet, 0.2)
        XCTAssertLessThanOrEqual(loud, 1)
    }

    /// A silent orb must still breathe — a frozen one reads as a hung app. Every
    /// state EXCEPT listening gets that from a time pulse; listening deliberately
    /// rests at zero drive (it is showing the user's own level, and inventing a
    /// swell there would be a lie), and gets its motion from the size breath in
    /// `radius` instead.
    func testEveryNonListeningStateStaysAliveWithNoAmplitude() {
        for state in VoiceState.allCases where state != .listening {
            for t in stride(from: 0.0, to: 6.0, by: 0.37) {
                let value = VoiceOrbGeometry.reactive(state: state, amplitude: 0, t: t)
                XCTAssertGreaterThan(value, 0, "\(state) at t=\(t)")
                XCTAssertLessThanOrEqual(value, 1.001, "\(state) at t=\(t)")
            }
        }
    }

    func testSilentListeningRestsButTheOrbStillBreathes() {
        XCTAssertEqual(VoiceOrbGeometry.reactive(state: .listening, amplitude: 0, t: 0), 0)
        let radii = stride(from: 0.0, to: 4.0, by: 0.5).map {
            VoiceOrbGeometry.radius(base: 100, reactive: 0, t: $0)
        }
        XCTAssertGreaterThan(Set(radii.map { ($0 * 1000).rounded() }).count, 1,
                             "a silent orb must still change size")
    }

    // MARK: - Motion

    /// Listening must PULSE, never spin: a whirling orb competes with the user.
    func testListeningDoesNotSpin() {
        XCTAssertEqual(VoiceOrbGeometry.spinSpeed(.listening), 0)
        for state in [VoiceState.idle, .connecting, .thinking, .speaking, .error] {
            XCTAssertGreaterThan(VoiceOrbGeometry.spinSpeed(state), 0, "\(state)")
        }
    }

    func testEveryStateUndulates() {
        for state in VoiceState.allCases {
            XCTAssertGreaterThan(VoiceOrbGeometry.undulationRate(state), 0, "\(state)")
        }
    }

    // MARK: - Radius / glow

    func testRadiusGrowsWithTheReactiveDrive() {
        let quiet = VoiceOrbGeometry.radius(base: 100, reactive: 0, t: 0)
        let loud = VoiceOrbGeometry.radius(base: 100, reactive: 1, t: 0)
        XCTAssertGreaterThan(loud, quiet)
        // Still inside the view at full swell (the halo lives outside it).
        XCTAssertLessThanOrEqual(quiet, 100)
        XCTAssertLessThanOrEqual(loud, 100)
    }

    func testRadiusScalesWithTheViewSize() {
        let small = VoiceOrbGeometry.radius(base: 50, reactive: 0.5, t: 1)
        let large = VoiceOrbGeometry.radius(base: 100, reactive: 0.5, t: 1)
        XCTAssertEqual(large, small * 2, accuracy: 0.0001)
    }

    func testHaloAlwaysSitsOutsideTheSphereAndBloomsWithTheVoice() {
        let calm = VoiceOrbGeometry.haloRadius(50, reactive: 0)
        let loud = VoiceOrbGeometry.haloRadius(50, reactive: 1)
        XCTAssertGreaterThan(calm, 50)
        XCTAssertGreaterThan(loud, calm)
    }

    func testBrightnessRisesWithEnergyAndDriveAndIsClamped() {
        let dim = VoiceOrbGeometry.brightness(energy: 0, reactive: 0)
        let bright = VoiceOrbGeometry.brightness(energy: 1, reactive: 1)
        XCTAssertGreaterThan(bright, dim)
        XCTAssertGreaterThanOrEqual(dim, 0.8)
        XCTAssertLessThanOrEqual(VoiceOrbGeometry.brightness(energy: 9, reactive: 9), 1.45)
    }

    func testRibbonHalfWidthGrowsWithTheDrive() {
        let calm = VoiceOrbGeometry.ribbonHalfWidth(100, reactive: 0)
        let loud = VoiceOrbGeometry.ribbonHalfWidth(100, reactive: 1)
        XCTAssertGreaterThan(loud, calm)
        XCTAssertGreaterThan(calm, 0)
    }

    func testWanderStaysSmall() {
        for t in stride(from: 0.0, to: 60.0, by: 0.9) {
            XCTAssertLessThan(abs(VoiceOrbGeometry.wander(t)), 0.35, "t=\(t)")
        }
    }

    func testThreeRibbonsWithDistinctPhases() {
        XCTAssertEqual(VoiceOrbGeometry.strands.count, 3)
        XCTAssertEqual(Set(VoiceOrbGeometry.strands.map(\.phase)).count, 3)
    }
}
