import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The workout screens, drawn before they reach a phone: picking a sport,
/// the live view running and paused, the summary, a failed start, and the
/// countdown as it counts.
@MainActor
final class WorkoutRenderTests: XCTestCase {
    private var controller: RingWorkoutController!
    private let suite = "WorkoutRenderTests"

    override func setUp() async throws {
        let session = RingSession(transport: makeRingTransport(FakeRingLink()), defaults: UserDefaults(suiteName: suite)!)
        controller = RingWorkoutController(session: session, ensureConnected: { true }, age: { 30 })
        controller.startTimeout = 30
    }

    private func tick(_ state: RingSportTick.State = .running, elapsed: Int, hr: Int?, steps: Int, meters: Int,
                      kcal: Double) -> RingSportTick {
        RingSportTick(sport: 7, state: state, elapsed: elapsed, heartRate: hr, steps: steps, distanceMeters: meters,
                      kilocalories: kcal)
    }

    /// A run 24 minutes in, as the ring would have reported it.
    private func running(paused: Bool = false) {
        for s in stride(from: 1, through: 1453, by: 7) {
            controller.receive(tick(elapsed: s, hr: 118 + (s % 60) / 2, steps: s * 2 + s / 3, meters: Int(Double(s) * 2.35),
                                    kcal: Double(s) * 0.17))
        }
        if paused { controller.pause() }
    }

    func testThePicker() throws {
        try RenderHarness.write(WorkoutPicker { _ in }, size: CGSize(width: 402, height: 874), name: "workout-picker")
    }

    func testTheLiveViewRunning() throws {
        running()
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 874),
                                name: "workout-live")
    }

    func testTheLiveViewPaused() throws {
        running(paused: true)
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 874),
                                name: "workout-paused")
    }

    func testTheSummary() throws {
        running()
        controller.end()
        controller.receive(tick(.ended, elapsed: 1460, hr: 131, steps: 3410, meters: 3431, kcal: 248))
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 1180),
                                name: "workout-summary")
    }

    func testAFailedStart() async throws {
        controller.countdownSeconds = 0
        controller.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.receive(tick(.ended, elapsed: 0, hr: nil, steps: 0, meters: 0, kcal: 0))
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 874),
                                name: "workout-failed")
    }

    func testTheCountdownCounts() throws {
        try RenderHarness.filmstrip(WorkoutLiveView(workout: controller), size: CGSize(width: 300, height: 420),
                                    name: "workout-countdown", changes: [{ self.controller.start(RingSport.withID(7)) }],
                                    times: [0.15, 0.5, 1.15, 1.5, 2.15, 2.6])
    }
}
