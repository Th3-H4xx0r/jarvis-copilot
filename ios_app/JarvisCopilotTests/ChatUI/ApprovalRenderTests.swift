import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The approval bar, a job card waiting on an approval, and the new-session
/// sheet, drawn to /tmp/ringshots to look at before installing.
@MainActor
final class ApprovalRenderTests: XCTestCase {
    func testTheApprovalSurfacesRender() throws {
        let waiting = HarnessJob(id: "j1", label: "Long Running", model: "@anthropic-api:claude-sonnet-5-5",
                                 startedAt: Date().timeIntervalSince1970 - 252, steps: 7,
                                 activity: "Needs your approval", workerSession: "c~bg",
                                 approval: .init(sessionID: "c~bg", command: "cd /root/research && rm -rf ./cache/*",
                                                 description: "recursive delete", canAlways: true))
        let running = HarnessJob(id: "j2", label: "Long Running", startedAt: Date().timeIntervalSince1970 - 40,
                                 steps: 3, activity: "Searching the web")
        let done = HarnessJob(id: "j3", label: "Long Running", status: "done", startedAt: 0, completedAt: 1252, steps: 18)
        let page = VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HarnessJobCard(job: running, onStop: {}, onOpen: {}, onAnswer: { _ in })
            HarnessJobCard(job: waiting, onStop: {}, onOpen: {}, onAnswer: { _ in })
            HarnessJobCard(job: done, onOpen: {})
            Spacer()
            ChatCommandApprovalBar(request: ChatCommandApproval(
                seq: 1, command: "cd /root/research && rm -rf ./cache/*", description: "recursive delete",
                canAlways: true)) { _ in }
        }
        .padding(.horizontal, 24)
        try RenderHarness.write(page, size: CGSize(width: 402, height: 874), name: "approvals")
    }

    func testTheNewSessionSheetRenders() throws {
        try RenderHarness.write(AgentLaunchSheet(store: AgentsStore()), size: CGSize(width: 402, height: 874),
                                name: "agent-launch-sheet")
    }
}
