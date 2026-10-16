import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Draws the per-agent Live Activity (Lock Screen, Dynamic Island) and its
/// settings section, so they're looked at before they reach a phone. PNGs go to
/// `RING_SNAPSHOT_DIR` (pass `TEST_RUNNER_RING_SNAPSHOT_DIR` to xcodebuild).
@MainActor
final class AgentActivityRenderTests: XCTestCase {

    typealias CS = AgentActivityAttributes.ContentState
    private let now = Date().timeIntervalSince1970

    private var samples: [(String, CS)] {
        [
            ("claude", CS(count: 3, waiting: 1, working: 1, name: "Claude Code", project: "jarvis-copilot",
                          state: "approval", step: "Needs approval: Bash: rm -rf build",
                          fingerprint: "fp", kind: "approval", since: now - 95, key: "d|claude|s",
                          bar: "p,w,i", actions: true, last: now, waitingSince: now - 13)),
            ("codex", CS(count: 1, working: 1, name: "Codex", project: "api-server", state: "working",
                         step: "Bash: npm test", since: now - 312, bar: "w", last: now)),
            ("gemini", CS(count: 2, name: "Gemini CLI", project: "website", state: "idle",
                          step: "Edit: index.html", bar: "i,i", last: now - 600)),
            ("copilot", CS(count: 1, waiting: 1, name: "Copilot CLI", project: "infra", state: "question",
                           step: "Which region should I deploy to?", fingerprint: "fq", kind: "question",
                           bar: "p", last: now, waitingSince: now - 40,
                           question: "Which region should I deploy to?",
                           options: ["us-east-1", "eu-west-1", "Other"])),
            ("codex", CS(count: 2, waiting: 1, name: "Codex", project: "api-server", state: "question",
                         fingerprint: "fx", kind: "question", bar: "p,w", last: now, waitingSince: now - 5,
                         question: "Should I also update the migration files for the new column?")),
            ("jarvis", CS(count: 1, working: 1, name: "Jarvis", project: "notes", state: "thinking",
                          since: now - 20, bar: "w", last: now)),
            ("claude", CS(count: 1, waiting: 1, name: "Claude Code", project: "jarvis-copilot", state: "question",
                          fingerprint: "fy", kind: "question", bar: "p", last: now, waitingSince: now - 15,
                          question: "Did the answer show up in the terminal as soon as you tapped it on the phone?",
                          options: ["Yes", "No"])),
        ]
    }

    /// The same request before and after Allow is tapped on the Lock Screen.
    func testRenderAnsweringInPlace() throws {
        let asks = samples[0].1
        let view = VStack(spacing: 10) {
            AgentLockScreenView(agent: "claude", st: asks)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
            AgentLockScreenView(agent: "claude", st: AgentLiveDecision.decided(asks, decision: "allow"))
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
            AgentLockScreenView(agent: "copilot",
                                st: AgentLiveDecision.decided(samples[3].1, decision: "answer", option: "eu-west-1"))
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
        }
        .padding(12)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), .black],
                                   startPoint: .top, endPoint: .bottom))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 560), name: "agent-la-answered")
    }

    func testRenderTheLockScreenActivities() throws {
        let view = VStack(spacing: 10) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                AgentLockScreenView(agent: s.0, st: s.1)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.82)))
            }
        }
        .padding(12)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), .black],
                                   startPoint: .top, endPoint: .bottom))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 1240), name: "agent-la-lockscreen")
    }

    func testRenderTheDynamicIsland() throws {
        let view = VStack(spacing: 14) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 18) {
                    // Compact: leading + trailing either side of the camera.
                    HStack {
                        AgentCompactLeading(agent: s.0, st: s.1)
                        Spacer()
                        AgentCompactTrailing(st: s.1)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 210, height: 36)
                    .background(Capsule().fill(.black))
                    // Minimal.
                    AgentMinimal(agent: s.0, st: s.1)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black))
                }
            }
            // Expanded: leading and trailing either side of the camera, the bottom below.
            ForEach([0, 6, 4, 1].map { samples[$0] }, id: \.1) { s in
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        AgentIslandLeading(agent: s.0, st: s.1)
                        Spacer(minLength: 0)
                        Capsule().fill(Color(white: 0.12)).frame(width: 90, height: 30)   // the camera
                        Spacer(minLength: 0)
                        AgentIslandTrailing(st: s.1)
                    }
                    AgentIslandBottom(st: s.1)
                }
                .padding(14)
                .frame(width: 370)
                .background(RoundedRectangle(cornerRadius: 44).fill(.black))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.85))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 1240), name: "agent-la-island")
    }

    func testRenderTheSettingsSection() throws {
        let (client, _) = JarvisAPI.mocked()
        let store = CodeMasterSettingsStore(api: CodingSessionsAPI(api: client))
        store.loading = false
        store.agentLive.set("cursor", false)
        let view = ScrollView {
            AgentActivitySettingsSection(store: store).padding(20)
        }
        try RenderHarness.write(view, size: CGSize(width: 390, height: 1240), name: "agent-la-settings")
    }
}
