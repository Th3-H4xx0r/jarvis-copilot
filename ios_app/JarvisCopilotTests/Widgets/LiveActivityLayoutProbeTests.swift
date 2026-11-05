import ActivityKit
import XCTest
@testable import JarvisCopilot

/// Every workout and agent Live Activity state as a REAL activity in the
/// simulator, each brought up with an alert so the system draws it over the home
/// screen — the expanded Dynamic Island on an island iPhone, the Lock Screen
/// layout as a banner on one without (iPhone 16e). This is the widget's own
/// renderer, which the in-app render tests are not: a workout timer sized for its
/// far-future end pushed the Lock Screen row off the card on his phone
/// (2026-11-03), and only a real activity shows that.
///
/// Opt-in: TEST_RUNNER_JC_LA_PROBE=1, TEST_RUNNER_JC_LA_SET=workout|agent|dashcam, or TEST_RUNNER_JC_LA_ONLY=<name> for one state (iOS drops alerts that come close together). It
/// prints "PROBE ready" (send the app to the background then, e.g. launch
/// Settings) and "PROBE shot <name>" as each one is up (screenshot then).
@MainActor
final class LiveActivityLayoutProbeTests: XCTestCase {
    typealias WS = RingWorkoutAttributes.ContentState
    typealias AS = AgentActivityAttributes.ContentState

    func testShowEveryState() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JC_LA_PROBE"] == "1", "opt-in probe")
        for a in Activity<RingWorkoutAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        for a in Activity<AgentActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        for a in Activity<DashcamSyncAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }

        // The app ends a workout activity with no workout behind it 20 s after
        // launch (RingWorkoutController's crash cleanup): to see the compact
        // island, which comes after the alert, start after that.
        if env["JC_LA_LATE"] == "1" { try await Task.sleep(nanoseconds: 22_000_000_000) }
        var shows: [(String, () async -> Void)] = []
        // iOS drops alerts that come too close together: one state per run.
        let only = env["JC_LA_ONLY"]
        let now = Date()
        if env["JC_LA_SET"] == nil || env["JC_LA_SET"] == "workout" {
            let workouts: [(String, String, String, WS)] = [
                ("run", "Run", "figure.run",
                 WS(running: true, reference: now.addingTimeInterval(-1453), frozenElapsed: 1453,
                    heartRate: 148, distanceKm: 5.51, zone: 3, miles: true)),
                ("rest", "Push day", "figure.strengthtraining.traditional",
                 WS(running: true, reference: now.addingTimeInterval(-1820), frozenElapsed: 1820, heartRate: 121,
                    distanceKm: nil, zone: 2, restEnds: now.addingTimeInterval(170), restStarted: now.addingTimeInterval(-10),
                    detail: "Bench Press · set 3 · 60 kg × 8", weight: "60", weightUnit: "kg", reps: 8)),
                ("lift", "Chest & Back", "figure.strengthtraining.traditional",
                 WS(running: true, reference: now.addingTimeInterval(-3900), frozenElapsed: 3900, heartRate: 134,
                    distanceKm: nil, zone: 3, detail: "Dumbbell Bench Press · set 1 · 22.5 kg × 10",
                    weight: "22.5", weightUnit: "kg", reps: 10)),
                ("cycle-paused", "Cycle", "figure.outdoor.cycle",
                 WS(running: false, reference: now, frozenElapsed: 3725, heartRate: nil, distanceKm: 21.4, zone: nil)),
                ("yoga", "Yoga", "figure.yoga",
                 WS(running: true, reference: now.addingTimeInterval(-640), frozenElapsed: 640,
                    heartRate: 92, distanceKm: nil, zone: 1)),
            ]
            for (name, sport, symbol, st) in workouts where only == nil || only == name {
                let activity = try Activity.request(attributes: RingWorkoutAttributes(sport: sport, symbol: symbol),
                                                    content: ActivityContent(state: st, staleDate: nil))
                shows.append((name, {
                    await activity.update(ActivityContent(state: st, staleDate: nil), alertConfiguration:
                        AlertConfiguration(title: "Workout", body: LocalizedStringResource(stringLiteral: name), sound: .default))
                }))
            }
        }
        if env["JC_LA_SET"] == nil || env["JC_LA_SET"] == "agent" {
            let t = now.timeIntervalSince1970
            let agents: [(String, String, AS)] = [
                ("approval", "claude", AS(count: 1, waiting: 1, name: "Claude Code", project: "jarvis-copilot",
                                          state: "approval", step: "Needs approval: Bash: rm -rf build && npm run build --prefix webui",
                                          fingerprint: "fp", kind: "approval", since: t - 95, key: "d|claude|s",
                                          bar: "p", actions: true, last: t, waitingSince: t - 13)),
                ("question", "claude", AS(count: 1, waiting: 1, name: "Claude Code", project: "jarvis-copilot",
                                          state: "question", fingerprint: "fq", kind: "question", bar: "p", last: t,
                                          waitingSince: t - 8,
                                          question: "Test: did this question show up on your phone's Lock Screen or Dynamic Island in the new …",
                                          options: ["Yes", "No"])),
                ("question-open", "codex", AS(count: 2, waiting: 1, name: "Codex", project: "api-server", state: "question",
                                              fingerprint: "fx", kind: "question", bar: "p,w", last: t, waitingSince: t - 5,
                                              question: "Should I also update the migration files for the new column?")),
                ("working", "claude", AS(count: 1, working: 1, name: "Claude Code", project: "jarvis-copilot",
                                         state: "working", step: "[Image #6] doesn't look good, not enough margins",
                                         since: t - 28, bar: "w", last: t)),
            ]
            for (name, agent, st) in agents where only == nil || only == name {
                let activity = try Activity.request(attributes: AgentActivityAttributes(agent: agent),
                                                    content: ActivityContent(state: st, staleDate: nil))
                shows.append((name, {
                    await activity.update(ActivityContent(state: st, staleDate: nil), alertConfiguration:
                        AlertConfiguration(title: "Agent", body: LocalizedStringResource(stringLiteral: name), sound: .default))
                }))
            }
        }
        if env["JC_LA_SET"] == "dashcam" {
            typealias DS = DashcamSyncAttributes.ContentState
            let clip = "2026_11_04_19_19_20_b.ts"
            let gb: Int64 = 1_073_741_824
            let syncs: [(String, DS)] = [
                ("dc-both", DS(downloadName: clip, downloadFraction: 0.26, toDownload: 77,
                               uploading: true, uploadFraction: 0.65, toUpload: 155,
                               phoneUsed: gb * 124 / 10, phoneCap: 20 * gb)),
                ("dc-up", DS(uploading: true, uploadFraction: 0.01, toUpload: 155,
                             phoneUsed: gb * 1234 / 10, phoneCap: 512 * gb)),
                ("dc-last", DS(uploading: true, uploadFraction: 1, toUpload: 1)),
            ]
            for (name, st) in syncs where only == nil || only == name {
                let activity = try Activity.request(attributes: DashcamSyncAttributes(cameraName: "HUAXIN A4"),
                                                    content: ActivityContent(state: st, staleDate: nil))
                shows.append((name, {
                    await activity.update(ActivityContent(state: st, staleDate: nil), alertConfiguration:
                        AlertConfiguration(title: "Dashcam", body: LocalizedStringResource(stringLiteral: name), sound: .default))
                }))
            }
        }
        print("PROBE ready")
        try await Task.sleep(nanoseconds: 10_000_000_000)   // time to leave the app
        for (name, show) in shows {
            await show()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            print("PROBE shot \(name)")
            // TEST_RUNNER_JC_LA_HOLD=<s>: keep it up longer (the island folds to compact after the alert).
            let hold = Double(env["JC_LA_HOLD"] ?? "") ?? 4.5
            try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        }
        for a in Activity<RingWorkoutAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        for a in Activity<AgentActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        for a in Activity<DashcamSyncAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
