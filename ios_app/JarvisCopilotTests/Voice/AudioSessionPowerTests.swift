import AVFoundation
import XCTest
@testable import JarvisCopilot

/// The battery half of the arbiter: what holding the session COSTS.
///
/// The keepalive renders silence for as long as the app is backgrounded, which is
/// most of a day. At the default IO buffer that is 40-200 CPU wakeups a second
/// with nothing to show for it; these pin the cheaper numbers, and — more
/// importantly — pin that they never leak into a voice turn, which reads the
/// hardware format and would otherwise capture the mic at 8 kHz.
@MainActor
final class AudioSessionPowerTests: XCTestCase {
    private func arbiter() -> (AudioSessionArbiter, MockAudioSessionApplying) {
        let session = MockAudioSessionApplying()
        return (AudioSessionArbiter(session: session), session)
    }

    func testTheKeepaliveAsksForACheapRateAndALongBuffer() throws {
        let (arbiter, session) = self.arbiter()
        try arbiter.hold(.keepalive)
        XCTAssertEqual(session.preferredSampleRate, AudioSessionArbiter.keepaliveSampleRate)
        XCTAssertEqual(session.preferredIOBufferDuration, 0.1)
    }

    /// The regression this pair exists to prevent: a turn starting under a live
    /// keepalive and inheriting 8 kHz, which `AudioInputEngine` would then read off
    /// `inputFormat(forBus:)` and feed to speech recognition.
    func testAVoiceTurnTakesTheHardwareBackToFullRate() throws {
        let (arbiter, session) = self.arbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)
        XCTAssertEqual(session.preferredSampleRate, 48_000)
        XCTAssertEqual(session.preferredIOBufferDuration, 0.02)
    }

    func testReleasingTheTurnGoesBackToTheCheapPlan() throws {
        let (arbiter, session) = self.arbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)
        try arbiter.release(.voice)
        XCTAssertEqual(session.preferredSampleRate, AudioSessionArbiter.keepaliveSampleRate,
                       "the keepalive is alone again and should stop paying for 48 kHz")
        XCTAssertEqual(session.preferredIOBufferDuration, 0.1)
    }

    /// A clip capture is real audio too: it must not record at the keepalive's rate.
    func testARecordingAlsoTakesTheHardwareBack() throws {
        let (arbiter, session) = self.arbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.recording)
        XCTAssertEqual(session.preferredSampleRate, 48_000)
    }
}

/// `EnergyReport` is what makes a battery change checkable on the phone itself,
/// so the arithmetic in it has to be right.
final class EnergyReportTests: XCTestCase {
    func testCpuPerHourNormalisesAgainstTimeAlive() {
        var report = EnergyReport(received: Date())
        report.cpuSeconds = 360
        report.foregroundSeconds = 1800
        report.backgroundSeconds = 5400          // two hours alive in total
        XCTAssertEqual(report.cpuSecondsPerHour ?? 0, 180, accuracy: 0.01)
    }

    /// A report covering a few seconds would divide into a meaningless rate.
    func testAnAlmostEmptyReportHasNoRate() {
        var report = EnergyReport(received: Date())
        report.cpuSeconds = 3
        report.foregroundSeconds = 10
        XCTAssertNil(report.cpuSecondsPerHour)
    }

    func testItRoundTripsThroughDefaults() throws {
        let defaults = UserDefaults(suiteName: "EnergyReportTests")!
        defer { defaults.removePersistentDomain(forName: "EnergyReportTests") }
        var report = EnergyReport(received: Date())
        report.backgroundAudioSeconds = 55_000
        report.save(defaults: defaults)
        XCTAssertEqual(EnergyReport.load(defaults: defaults)?.backgroundAudioSeconds, 55_000)
    }
}
