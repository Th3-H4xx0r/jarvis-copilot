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

/// The shared page pieces (JcUnified.swift) on one page, to look at side by side
/// with Health and Devices.
@MainActor
final class UnifiedPiecesRenderTests: XCTestCase {
    private enum Day: String, CaseIterable, Identifiable {
        case today = "Today", yesterday = "Yesterday", sat = "Sat 31", fri = "Fri 30", thu = "Thu 29", wed = "Wed 28"
        var id: String { rawValue }
    }
    private enum Half: String, CaseIterable, Identifiable {
        case server = "Server", wearables = "Wearables"
        var id: String { rawValue }
    }

    func testTheUnifiedPiecesRender() throws {
        let page = NavigationStack {
            JcPage("Agents") {
                JcSegmented(items: Half.allCases, selection: .constant(.wearables), label: { $0.rawValue })
                    .frame(maxWidth: 280).frame(maxWidth: .infinity)
                JcSegmented(items: Day.allCases, selection: .constant(.today), label: { $0.rawValue })
                    .padding(.top, 12)
                JcSectionLabel("Needs you") { Text("2") }
                JcCard(padding: 0) {
                    JcRow(symbol: "terminal", title: "jarvis-copilot", subtitle: "Claude Code · Bash: npm test") {
                        JcSmallAction("Allow", symbol: "checkmark") {}
                    }
                    JcRow(symbol: "folder", title: "Projects", subtitle: "4 sessions", action: {})
                    JcRow(symbol: "clock", title: "Last run", value: "2 min ago")
                    JcShowAllRow {}
                }
                JcSectionLabel("Body battery")
                JcCard {
                    Text("No battery yet").font(.system(size: 20, weight: .medium)).foregroundStyle(JcTheme.text)
                    Text("It starts from a night of sleep on a linked wearable")
                        .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                }
                JcSectionLabel("Empty")
                JcCard { JcEmptyState(symbol: "tray", title: "Nothing here", subtitle: "New sessions show up here") }
            } actions: {
                JcPageButton("plus", label: "New") {}
                JcPageButton("ellipsis", label: "More") {}
            } leading: {
                JcPageButton("sidebar.left", label: "Chats") {}
            }
        }
        try RenderHarness.write(page, size: CGSize(width: 402, height: 874), name: "unified-pieces")
    }
}
