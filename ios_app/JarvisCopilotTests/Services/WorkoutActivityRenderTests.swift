import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Draws the workout Live Activity (Lock Screen, Dynamic Island) for several
/// sports and strength's lifting / resting states, so they're looked at before
/// they reach a phone. PNGs go to `RING_SNAPSHOT_DIR`.
@MainActor
final class WorkoutActivityRenderTests: XCTestCase {

    typealias CS = RingWorkoutAttributes.ContentState

    private var samples: [(sport: String, symbol: String, state: CS)] {
        let now = Date()
        return [
            ("Run", "figure.run",
             CS(running: true, reference: now.addingTimeInterval(-1453), frozenElapsed: 1453,
                heartRate: 148, distanceKm: 5.51, zone: 3, miles: true)),
            ("Push day", "figure.strengthtraining.traditional",
             CS(running: true, reference: now.addingTimeInterval(-1820), frozenElapsed: 1820, heartRate: 121,
                distanceKm: nil, zone: 2, restEnds: now.addingTimeInterval(72), restStarted: now.addingTimeInterval(-48),
                detail: "Bench Press · set 3 · 60 kg × 8", weight: "60", weightUnit: "kg", reps: 8)),
            ("Push day", "figure.strengthtraining.traditional",
             CS(running: true, reference: now.addingTimeInterval(-1900), frozenElapsed: 1900, heartRate: 134,
                distanceKm: nil, zone: 3, detail: "Incline Dumbbell Press · set 1 · 22.5 kg × 10",
                weight: "22.5", weightUnit: "kg", reps: 10)),
            ("Cycle", "figure.outdoor.cycle",
             CS(running: false, reference: now, frozenElapsed: 3725, heartRate: nil, distanceKm: 21.4, zone: nil)),
            ("Yoga", "figure.yoga",
             CS(running: true, reference: now.addingTimeInterval(-640), frozenElapsed: 640,
                heartRate: 92, distanceKm: nil, zone: 1)),
        ]
    }

    func testRenderTheLockScreen() throws {
        let samples = self.samples
        let view = VStack(spacing: 10) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                WorkoutLockScreenView(sport: s.sport, symbol: s.symbol, state: s.state)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), .black],
                                   startPoint: .top, endPoint: .bottom))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 860), name: "workout-la-lockscreen")
    }

    func testRenderTheDynamicIsland() throws {
        let samples = self.samples
        let view = VStack(spacing: 14) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 18) {
                    HStack {
                        WorkoutCompactLeading(symbol: s.symbol)
                        Spacer()
                        WorkoutCompactTrailing(state: s.state)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 210, height: 36)
                    .background(Capsule().fill(.black))
                    WorkoutCompactLeading(symbol: s.symbol)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black))
                }
            }
            ForEach([0, 1, 2], id: \.self) { i in
                let s = samples[i]
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        WorkoutIslandLeading(sport: s.sport, symbol: s.symbol, state: s.state)
                        Spacer(minLength: 0)
                        Capsule().fill(Color(white: 0.12)).frame(width: 90, height: 30)   // the camera
                        Spacer(minLength: 0)
                        WorkoutIslandTrailing(state: s.state)
                    }
                    WorkoutIslandBottom(sport: s.sport, state: s.state)
                }
                .padding(14)
                .frame(width: 370)
                .background(RoundedRectangle(cornerRadius: 44).fill(.black))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.85))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 1000), name: "workout-la-island")
    }

    /// iOS cuts a Lock Screen activity off at 160 pt: every state must fit.
    func testEveryLockScreenStateFitsUnderTheCap() {
        for s in samples {
            let host = UIHostingController(rootView: WorkoutLockScreenView(sport: s.sport, symbol: s.symbol, state: s.state))
            let size = host.sizeThatFits(in: CGSize(width: 350, height: 1000))
            XCTAssertLessThanOrEqual(size.height, 158, "\(s.sport): \(size.height) pt")
        }
    }

    func testNextSetSplitsTheExerciseFromTheSet() {
        let next = WorkoutNextSet("Bench Press · set 3 · 60 kg × 8")
        XCTAssertEqual(next?.exercise, "Bench Press")
        XCTAssertEqual(next?.number, "Set 3")
        XCTAssertEqual(next?.values, "60 kg × 8")
        XCTAssertEqual(next?.set, "Set 3 · 60 kg × 8")
        XCTAssertEqual(WorkoutNextSet("Plank")?.set, "")
        XCTAssertNil(WorkoutNextSet(nil))
        XCTAssertNil(WorkoutNextSet(""))
    }

    func testEveryButtonsActionRoundTrips() {
        for action in WorkoutLiveAction.allCases {
            XCTAssertEqual(WorkoutLiveAction(rawValue: WorkoutLiveActionIntent(action).action), action)
        }
    }

    func testAnEndedRestFallsBackToTheWorkoutClock() {
        let now = Date()
        var state = samples[1].state
        XCTAssertNotNil(RestWindow(state, isStale: false, now: now))
        XCTAssertNil(RestWindow(state, isStale: true, now: now))
        state.restEnds = now.addingTimeInterval(-1)
        XCTAssertNil(RestWindow(state, isStale: false, now: now))
    }
}
