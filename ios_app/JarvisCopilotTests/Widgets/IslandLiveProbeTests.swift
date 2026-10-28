import ActivityKit
import XCTest
@testable import JarvisCopilot

/// A real Jarvis Live Activity in the simulator, stepped through a talk's states
/// slowly enough to screenshot the island (frames show whether anything animates
/// and whether each state draws). Opt-in: TEST_RUNNER_JC_ISLAND_PROBE=1.
@MainActor
final class IslandLiveProbeTests: XCTestCase {
    func testStepTheIslandThroughATalk() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JC_ISLAND_PROBE"] == "1", "opt-in probe")
        for activity in Activity<JarvisActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        typealias State = JarvisActivityAttributes.ContentState
        var st = State()
        st.state = "listening"
        st.stateSince = Date().timeIntervalSince1970
        let activity = try Activity.request(attributes: JarvisActivityAttributes(title: "JARVIS"),
                                            content: ActivityContent(state: st, staleDate: nil))
        print("PROBE started listening")
        try await Task.sleep(nanoseconds: 12_000_000_000)   // time to leave the app
        let steps: [(String, String, String)] = [
            ("listening", "What's on my calendar", ""),
            ("thinking", "What's on my calendar tomorrow?", ""),
            ("speaking", "What's on my calendar tomorrow?", "Stand-up with Maya at 9:30, then the dentist at 11, and the gym at 6."),
            ("idle", "What's on my calendar tomorrow?", "Stand-up at 9:30, then the dentist at 11."),
        ]
        let alerts = ProcessInfo.processInfo.environment["JC_ISLAND_ALERTS"] == "1"
        for (state, said, reply) in steps {
            if state != st.state { st.stateSince = Date().timeIntervalSince1970 }
            st.state = state
            st.transcript = said
            st.activity = reply
            let content = ActivityContent(state: st, staleDate: nil)
            if alerts, state != "idle" {
                await activity.update(content, alertConfiguration: AlertConfiguration(
                    title: "Jarvis", body: LocalizedStringResource(stringLiteral: state), sound: .default))
            } else {
                await activity.update(content)
            }
            print("PROBE now \(state)")
            try await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }
}
