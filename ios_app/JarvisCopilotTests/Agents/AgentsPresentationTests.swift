import XCTest
@testable import JarvisCopilot

/// The Agents tab's presentation rules: status marks, what a step and an
/// approval say, what a failed send tells you, and when a session screen falls
/// back from the transcript to the agent's last turn.
@MainActor
final class AgentsPresentationTests: XCTestCase {

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

    // MARK: rows

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
        let offline = AgentSendFailure.from(reason: "owner_offline")
        XCTAssertEqual(offline, .macOffline)
        XCTAssertTrue(offline.offersContinue, "an asleep Mac's session can move to the server")
        XCTAssertTrue(offline.message.contains("asleep or offline"), offline.message)
        XCTAssertEqual(AgentSendFailure.from(reason: "no_runtime"), .noRuntime)
        XCTAssertEqual(AgentSendFailure.from(reason: "ended"), .ended)
        XCTAssertEqual(AgentSendFailure.from(reason: "moving"), .moving)
        XCTAssertEqual(AgentSendFailure.from(reason: "no_session"), .gone)
        XCTAssertFalse(AgentSendFailure.ended.offersContinue)
        // Anything else is the server's own sentence.
        XCTAssertEqual(AgentSendFailure.from(reason: "The VS Code window is closed."),
                       .other("The VS Code window is closed."))
        XCTAssertEqual(AgentSendFailure.from(APIError.http(status: 502, message: "could not type")),
                       .other("could not type"))
        XCTAssertEqual(AgentSendFailure.from(CodingServerError(message: "nope")), .other("nope"))
    }

    // MARK: outgoing

    func testOutgoingCaptionsFollowTheirPhase() {
        var o = AgentOutgoing(text: "run the tests", baseline: 0)
        XCTAssertEqual(o.caption, "Sending…")
        o.phase = .sent
        XCTAssertEqual(o.caption, "Sent")
        o.phase = .queued
        XCTAssertEqual(o.caption, "Queued — will send when the turn ends")
        o.phase = .delivered
        XCTAssertEqual(o.caption, "Delivered")
        o.phase = .failed(.macOffline)
        XCTAssertEqual(o.caption, "Failed: " + AgentSendFailure.macOffline.message)
        XCTAssertEqual(o.failure, .macOffline)
    }

    func testTheServersDeliveryBecomesThePhase() {
        XCTAssertEqual(AgentOutgoing.Phase(AgentDelivery(state: .sent)), .sent)
        XCTAssertEqual(AgentOutgoing.Phase(AgentDelivery(state: .queued)), .queued)
        XCTAssertEqual(AgentOutgoing.Phase(AgentDelivery(state: .delivered)), .delivered)
        XCTAssertEqual(AgentOutgoing.Phase(AgentDelivery(state: .failed, reason: "owner_offline")),
                       .failed(.macOffline))
    }

    func testASentMessageLeavesOnceTheConversationShowsIt() {
        let sent = AgentOutgoing(text: "continue", baseline: 1, phase: .sent)
        let queued = AgentOutgoing(text: "continue", baseline: 1, phase: .queued)
        let failed = AgentOutgoing(text: "continue", baseline: 1, phase: .failed(.macOffline))
        let sending = AgentOutgoing(text: "continue", baseline: 1)
        // The old "continue" is already there: the new one hasn't landed yet.
        XCTAssertEqual(AgentOutgoing.reconcile([sent, queued, failed, sending], prompts: ["continue"]).count, 4)
        // A second "continue" shows up: the sent and queued ones go, the others stay.
        let left = AgentOutgoing.reconcile([sent, queued, failed, sending], prompts: ["continue", " continue\n"])
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
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: "claude|s1", transcript: t, turn: turn,
                                                    detailLoaded: true), .transcript)
    }

    func testItWaitsForTheFirstTranscriptPage() {
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: "claude|s1", transcript: CodingTranscript(),
                                                    turn: turn, detailLoaded: true), .loading)
    }

    func testItFallsBackToTheLastTurn() {
        // No transcript source at all (Gemini, a session the server never saw).
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: nil, transcript: CodingTranscript(),
                                                    turn: turn, detailLoaded: true), .lastTurn)
        // 409: no transcript yet.
        var none = CodingTranscript()
        none.loading = false
        none.noTranscript = true
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: "claude|s1", transcript: none, turn: turn,
                                                    detailLoaded: true), .lastTurn)
        // Any other failure leaves an empty, loaded transcript.
        var failed = CodingTranscript()
        failed.loading = false
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: "claude|s1", transcript: failed, turn: turn,
                                                    detailLoaded: true), .lastTurn)
    }

    func testNothingToShowIsEmptyOnceLoaded() {
        let blank = AgentTurn(json: [:])
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: nil, transcript: CodingTranscript(),
                                                    turn: blank, detailLoaded: false), .loading)
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: nil, transcript: CodingTranscript(),
                                                    turn: blank, detailLoaded: true), .empty)
        XCTAssertEqual(AgentTranscriptChoice.choose(transcriptId: nil, transcript: CodingTranscript(),
                                                    turn: nil, detailLoaded: true), .empty)
    }
}
