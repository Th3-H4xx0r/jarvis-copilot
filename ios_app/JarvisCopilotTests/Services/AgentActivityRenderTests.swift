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
                          bar: "p,w,i", actions: true, last: now)),
            ("codex", CS(count: 1, working: 1, name: "Codex", project: "api-server", state: "working",
                         step: "Bash: npm test", since: now - 312, bar: "w", last: now)),
            ("gemini", CS(count: 2, name: "Gemini CLI", project: "website", state: "idle",
                          step: "Edit: index.html", bar: "i,i", last: now - 600)),
            ("copilot", CS(count: 1, waiting: 1, name: "Copilot CLI", project: "infra", state: "question",
                           step: "Which region should I deploy to?", kind: "question", bar: "p", last: now)),
            ("jarvis", CS(count: 1, working: 1, name: "Jarvis", project: "notes", state: "thinking",
                          since: now - 20, bar: "w", last: now)),
        ]
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
        try RenderHarness.write(view, size: CGSize(width: 390, height: 840), name: "agent-la-lockscreen")
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
            // Expanded, for the first two.
            ForEach(Array(samples.prefix(2).enumerated()), id: \.offset) { _, s in
                VStack(spacing: 8) {
                    HStack(alignment: .top) {
                        AgentIslandLeading(agent: s.0, st: s.1)
                        Spacer()
                        AgentIslandTrailing(st: s.1)
                    }
                    AgentIslandBottom(st: s.1)
                }
                .padding(14)
                .frame(width: 370)
                .background(RoundedRectangle(cornerRadius: 40).fill(.black))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.85))
        try RenderHarness.write(view, size: CGSize(width: 390, height: 680), name: "agent-la-island")
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
