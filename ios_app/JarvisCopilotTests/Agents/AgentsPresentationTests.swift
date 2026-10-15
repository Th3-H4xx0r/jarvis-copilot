import XCTest
@testable import JarvisCopilot

/// The Agents tab's presentation rules: status marks, the Needs you / Working /
/// Recent grouping, what a row says, what a failed send tells you, and when a
/// session screen falls back from the transcript to the agent's last turn.
@MainActor
final class AgentsPresentationTests: XCTestCase {

    private func session(_ key: String, state: String, at: Double = 1781000000,
                         prompt: String? = "fix the login test", project: String = "app",
                         step: String = "", term: [String: Any]? = ["bundle_id": "com.apple.Terminal"],
                         codingSession: String? = nil) -> AgentSessionItem {
        var json: [String: Any] = [
            "key": key, "agent": "claude", "session_id": "s-\(key)", "cwd": "/Users/p/code/\(project)",
            "project": project, "state": state, "step": step, "started_at": at - 60, "last_event_at": at,
        ]
        if let term { json["terminal"] = term }
        if let prompt { json["turn_summary"] = ["prompt": prompt, "started_at": at - 50] }
        if let codingSession { json["coding_session_id"] = codingSession }
        return AgentSessionItem(json: json)
    }

    private func request(_ rid: String, key: String, kind: String = "permission",
                         command: String = "rm -rf build", tool: String = "Bash") -> AgentRequest {
        AgentRequest.from(["request_id": rid, "fingerprint": "fp-\(rid)", "kind": kind, "tool": tool,
                           "summary": "\(tool): \(command)", "command": command, "key": key,
                           "agent": "claude", "questions": kind == "ask"
                               ? [["question": "Which database?", "options": [["label": "Postgres"]]]] : []])!
    }

    // MARK: status

    func testStatusMapsEveryState() {
        XCTAssertEqual(AgentRowStatus.of(.working, waiting: false), .working)
        XCTAssertEqual(AgentRowStatus.of(.thinking, waiting: false), .working)
        XCTAssertEqual(AgentRowStatus.of(.approval, waiting: false), .waiting)
        XCTAssertEqual(AgentRowStatus.of(.question, waiting: false), .waiting)
        XCTAssertEqual(AgentRowStatus.of(.finished, waiting: false), .finished)
        XCTAssertEqual(AgentRowStatus.of(.error, waiting: false), .failed)
        XCTAssertEqual(AgentRowStatus.of(.ratelimit, waiting: false), .rateLimited)
        XCTAssertEqual(AgentRowStatus.of(.idle, waiting: false), .idle)
    }

    func testAWaitingRequestWinsOverTheHookState() {
        // The hooks can still say "working" for a beat after the card arrives.
        XCTAssertEqual(AgentRowStatus.of(.working, waiting: true), .waiting)
        XCTAssertEqual(AgentRowStatus.of(.finished, waiting: true), .waiting)
    }

    func testWaitingIsAmberAndNeighboursDiffer() {
        XCTAssertEqual(AgentRowStatus.waiting.color, JcTheme.amber)
        let colors = [AgentRowStatus.waiting, .working, .finished, .failed].map(\.color)
        XCTAssertEqual(Set(colors.map { "\($0)" }).count, colors.count)
    }

    func testPillLabelsSayWhatItWaitsOn() {
        XCTAssertEqual(AgentRowStatus.label(.approval, request: nil), "Needs approval")
        XCTAssertEqual(AgentRowStatus.label(.working, request: request("r1", key: "k", kind: "ask")),
                       "Has a question")
        XCTAssertEqual(AgentRowStatus.label(.thinking, request: nil), "Thinking")
        XCTAssertEqual(AgentRowStatus.label(.working, request: nil), "Working")
        XCTAssertEqual(AgentRowStatus.label(.finished, request: nil), "Finished")
        XCTAssertEqual(AgentRowStatus.label(.error, request: nil), "Failed")
    }

    // MARK: grouping

    func testSectionsGoNeedsYouWorkingRecentNewestFirst() {
        let sessions = [
            session("done-old", state: "finished", at: 100),
            session("work", state: "working", at: 300),
            session("ask", state: "question", at: 200),
            session("done-new", state: "finished", at: 400),
            session("held", state: "working", at: 250),
            session("limit", state: "ratelimit", at: 150),
            session("idle", state: "idle", at: 500),
            session("broke", state: "error", at: 350),
        ]
        let sections = AgentsGrouping.sections(sessions, requests: [request("r1", key: "held")])
        XCTAssertEqual(sections.map(\.kind), [.needsYou, .working, .recent])
        XCTAssertEqual(sections[0].sessions.map(\.key), ["held", "ask"])
        XCTAssertEqual(sections[1].sessions.map(\.key), ["work", "limit"])
        XCTAssertEqual(sections[2].sessions.map(\.key), ["idle", "done-new", "broke", "done-old"])
        XCTAssertEqual(sections.map(\.kind.title), ["Needs you", "Working", "Recent"])
    }

    func testEmptySectionsAreLeftOut() {
        let sections = AgentsGrouping.sections([session("a", state: "finished")], requests: [])
        XCTAssertEqual(sections.map(\.kind), [.recent])
        XCTAssertTrue(AgentsGrouping.sections([], requests: []).isEmpty)
    }

    func testOrphanedRequestsAreKeptAndCounted() {
        let sessions = [session("a", state: "approval"), session("b", state: "working")]
        let requests = [request("r1", key: "a"), request("r2", key: "gone")]
        XCTAssertEqual(AgentsGrouping.orphans(requests, sessions: sessions).map(\.requestId), ["r2"])
        // One row waits (a) and one card has no row (r2): the list shows two.
        XCTAssertEqual(AgentsGrouping.waitingCount(sessions, requests: requests), 2)
        XCTAssertEqual(AgentsGrouping.waitingCount([session("b", state: "working")], requests: []), 0)
    }

    // MARK: rows

    func testTitleIsThePromptsFirstLineElseTheProject() {
        XCTAssertEqual(AgentsPresentation.title(session("a", state: "working",
                                                        prompt: "  fix the login test\nand the docs")),
                       "fix the login test")
        XCTAssertEqual(AgentsPresentation.title(session("a", state: "idle", prompt: nil, project: "api")), "api")
        XCTAssertEqual(AgentsPresentation.title(session("a", state: "idle", prompt: "   ", project: "api")), "api")
    }

    func testSubtitleIsProjectAgentTerminal() {
        XCTAssertEqual(AgentsPresentation.subtitle(session("a", state: "working")),
                       "app · Claude Code · Terminal")
        // The project is already the title.
        XCTAssertEqual(AgentsPresentation.subtitle(session("a", state: "idle", prompt: nil, term: nil)),
                       "Claude Code")
    }

    func testDetailSaysWhatItWaitsOnOrDoes() {
        let waiting = session("a", state: "approval")
        XCTAssertEqual(AgentsPresentation.detail(waiting, request: request("r1", key: "a")),
                       AgentRowDetail(text: "Wants to run rm -rf build", tone: .waiting))
        XCTAssertEqual(AgentsPresentation.detail(waiting, request: request("r1", key: "a", kind: "ask")),
                       AgentRowDetail(text: "Which database?", tone: .waiting))
        XCTAssertEqual(AgentsPresentation.detail(waiting, request: nil),
                       AgentRowDetail(text: "Needs approval", tone: .waiting))
        XCTAssertEqual(AgentsPresentation.detail(session("b", state: "working", step: "Bash: npm test"), request: nil),
                       AgentRowDetail(text: "Running npm test…", tone: .working))
        XCTAssertEqual(AgentsPresentation.detail(session("b", state: "thinking"), request: nil),
                       AgentRowDetail(text: "Thinking…", tone: .working))
        XCTAssertNil(AgentsPresentation.detail(session("c", state: "finished"), request: nil))
    }

    func testLiveStepsReadAsSentences() {
        XCTAssertEqual(AgentsPresentation.liveStep("Bash: npm test"), "Running npm test…")
        XCTAssertEqual(AgentsPresentation.liveStep("Read app.ts"), "Reading app.ts…")
        XCTAssertEqual(AgentsPresentation.liveStep("Search loginHandler"), "Search loginHandler")
        XCTAssertEqual(AgentsPresentation.liveStep(""), "Thinking…")
        // Claude Code's own status line wins when the transcript has one.
        XCTAssertEqual(AgentsPresentation.working(statusLine: "✳ Zesting… (50s · ↑ 2.0k tokens)",
                                                  step: "Bash: make", state: .working), "Zesting… · 50s")
        XCTAssertEqual(AgentsPresentation.working(statusLine: nil, step: "", state: .thinking), "Thinking…")
    }

    func testApprovalTitles() {
        XCTAssertEqual(AgentsPresentation.approvalTitle(request("r1", key: "k")),
                       "Allow Claude Code to run this command?")
        XCTAssertEqual(AgentsPresentation.approvalTitle(request("r1", key: "k", command: "/w/src/app.ts", tool: "Edit")),
                       "Allow Claude Code to edit app.ts?")
        XCTAssertEqual(AgentsPresentation.approvalTitle(request("r1", key: "k", kind: "ask")),
                       "Claude Code has a question")
    }

    func testFoldersAreRelativeToTheSession() {
        XCTAssertEqual(AgentsPresentation.folder(of: "/Users/p/code/app/src/ui/a.ts", cwd: "/Users/p/code/app"), "src/ui")
        XCTAssertEqual(AgentsPresentation.folder(of: "/Users/p/code/app/a.ts", cwd: "/Users/p/code/app/"), "")
        XCTAssertEqual(AgentsPresentation.folder(of: "/Users/p/notes/x.md", cwd: "/Users/p/code/app"), "~/notes")
        XCTAssertEqual(AgentsPresentation.shortPath("/Users/p/code/app"), "~/code/app")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1781000000)
        XCTAssertEqual(AgentsPresentation.time(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(AgentsPresentation.time(now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(AgentsPresentation.time(now.addingTimeInterval(-3 * 3600), now: now), "3h")
    }

    // MARK: send failures

    func testSendFailuresReadAsWhatToDo() {
        let off = AgentSendFailure.from(APIError.http(status: 403, message: "turn on …"))
        XCTAssertEqual(off, .phoneInstructionsOff)
        XCTAssertTrue(off.opensSettings)
        XCTAssertTrue(off.message.contains("Instructions from the phone"), off.message)
        XCTAssertTrue(off.message.contains("Code Master"), off.message)

        // A 409 carries the server's own reason (idle in VS Code, Jarvis still answering…).
        let idle = AgentSendFailure.from(APIError.http(status: 409, message: "This session is waiting at its prompt in VS Code."))
        XCTAssertEqual(idle, .other("This session is waiting at its prompt in VS Code."))
        XCTAssertFalse(idle.opensSettings)
        XCTAssertEqual(AgentSendFailure.from(APIError.http(status: 409, message: "")), .noTerminal)

        let offline = AgentSendFailure.from(APIError.http(status: 503, message: "offline"))
        XCTAssertEqual(offline, .macOffline)
        XCTAssertTrue(offline.message.contains("offline"), offline.message)

        XCTAssertEqual(AgentSendFailure.from(APIError.http(status: 502, message: "could not type")),
                       .other("could not type"))
        XCTAssertEqual(AgentSendFailure.from(CodingServerError(message: "nope")), .other("nope"))
    }

    // MARK: outgoing

    func testOutgoingCaptionsFollowTheirPhase() {
        var o = AgentOutgoing(text: "run the tests", baseline: 0)
        XCTAssertEqual(o.caption, "Sending…")
        o.phase = .sent(via: "queued")
        XCTAssertEqual(o.caption, "Queued · it gets this when it finishes its current step")
        o.phase = .sent(via: "typed")
        XCTAssertEqual(o.caption, "Sent · typed into the terminal")
        o.phase = .sent(via: "terminal")
        XCTAssertEqual(o.caption, "Sent · typed into the terminal")
        o.phase = .sent(via: "chat")
        XCTAssertEqual(o.caption, "Sent to Jarvis")
        o.phase = .failed(.macOffline)
        XCTAssertEqual(o.caption, AgentSendFailure.macOffline.message)
    }

    func testASentInstructionLeavesOnceTheConversationShowsIt() {
        let sent = AgentOutgoing(text: "continue", baseline: 1, phase: .sent(via: "terminal"))
        let failed = AgentOutgoing(text: "continue", baseline: 1, phase: .failed(.macOffline))
        let sending = AgentOutgoing(text: "continue", baseline: 1)
        // The old "continue" is already there: the new one hasn't landed yet.
        XCTAssertEqual(AgentOutgoing.reconcile([sent, failed, sending], prompts: ["continue"]).count, 3)
        // A second "continue" shows up: the sent one goes, the others stay.
        let left = AgentOutgoing.reconcile([sent, failed, sending], prompts: ["continue", " continue\n"])
        XCTAssertEqual(left.map(\.id), [failed.id, sending.id])
        XCTAssertEqual(AgentOutgoing.count("continue", in: ["continue", "go", "continue "]), 2)
    }

    // MARK: transcript or last turn

    private let turn = AgentTurn(json: ["prompt": "fix it", "final": "Done.",
                                        "actions": [["tool": "Bash", "summary": "Bash: make"]]])

    func testTheTranscriptWinsWhenThereIsOne() {
        var t = CodingTranscript()
        t.loading = false
        t.messages = [CodingChatMessage(i: 0, role: "user", text: "fix it")]
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: "cs_1", transcript: t, turn: turn,
                                                    detailLoaded: true), .transcript)
    }

    func testItWaitsForTheFirstTranscriptPage() {
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: "cs_1", transcript: CodingTranscript(),
                                                    turn: turn, detailLoaded: true), .loading)
    }

    func testItFallsBackToTheLastTurn() {
        // No coding session at all (Codex, Gemini, a session the server never saw).
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: nil, transcript: CodingTranscript(),
                                                    turn: turn, detailLoaded: true), .lastTurn)
        // 409: no transcript yet.
        var none = CodingTranscript()
        none.loading = false
        none.noTranscript = true
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: "cs_1", transcript: none, turn: turn,
                                                    detailLoaded: true), .lastTurn)
        // Any other failure leaves an empty, loaded transcript.
        var failed = CodingTranscript()
        failed.loading = false
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: "cs_1", transcript: failed, turn: turn,
                                                    detailLoaded: true), .lastTurn)
    }

    func testNothingToShowIsEmptyOnceLoaded() {
        let blank = AgentTurn(json: [:])
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: nil, transcript: CodingTranscript(),
                                                    turn: blank, detailLoaded: false), .loading)
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: nil, transcript: CodingTranscript(),
                                                    turn: blank, detailLoaded: true), .empty)
        XCTAssertEqual(AgentTranscriptChoice.choose(codingSessionId: nil, transcript: CodingTranscript(),
                                                    turn: nil, detailLoaded: true), .empty)
    }
}
