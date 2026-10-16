import XCTest
@testable import Jarvis

/// Hand-off jobs in the Agents tab, and their answers read out.
///
/// Pranav (2026-10-16): "whenever it reroutes to another agent to complete it,
/// it should basically start speaking again once it gets a response from the
/// agent. Also, this response should be shown in the agents tab".
final class HandoffJobsTests: XCTestCase {

    private func entry(_ id: String = "j1", status: String = "running", completedAt: Double? = nil,
                       result: String = "") -> [String: Any] {
        var e: [String: Any] = [
            "id": id, "session_id": "s1", "label": "claude", "model": "@claude-code:claude-sonnet-5-5",
            "status": status, "started_at": 1_000.0, "steps": 2, "activity": "Searching the web",
            "task": "compare these against dealer and lease offers", "note": "Compare offers",
            "surface": "voice", "device": "Pranav's MacBook",
            "trail": [["t": "Searching the web", "detail": "lease offers"]], "result": result, "error": ""]
        e["completed_at"] = completedAt.map { $0 as Any } ?? NSNull()
        return e
    }

    func testAJobReadsAsWhoHasItWhatItsDoingAndWhereItCameFrom() {
        let job = MacJob(json: entry())
        XCTAssertEqual(job.key, "job:j1")
        XCTAssertEqual(job.agentName, "Claude")
        XCTAssertEqual(job.modelName, "claude-sonnet-5-5")
        XCTAssertEqual(job.state, .working)
        XCTAssertEqual(job.line, "Searching the web")
        XCTAssertEqual(job.origin, "By voice on Pranav's MacBook")
        XCTAssertEqual(job.trail.first?.detail, "lease offers")
        XCTAssertNil(job.completedAt)
        XCTAssertEqual(job.elapsed(now: Date(timeIntervalSince1970: 1_072)), "1m 12s")
    }

    func testAnEndedJobShowsItsAnswer() {
        let done = MacJob(json: entry(status: "done", completedAt: 1_030, result: "The lease wins.\nDetails below."))
        XCTAssertEqual(done.state, .finished)
        XCTAssertEqual(done.line, "The lease wins.")
        XCTAssertEqual(done.elapsed(), "30s")
        XCTAssertEqual(MacJob(json: entry(status: "failed")).state, .error)
        XCTAssertEqual(MacJob(json: ["id": "x", "label": "Long Running"]).agentName, "Long Running")
    }

    @MainActor
    func testTheFeedFillsTheAgentsTabAndCountsAsWorking() {
        let model = AppModel()
        model.handle(["type": "topic", "topic": "harness_jobs",
                      "data": ["jobs": [entry("a"), entry("b", status: "done", completedAt: Date().timeIntervalSince1970)]]])
        XCTAssertEqual(model.jobs.map(\.id), ["a", "b"])
        XCTAssertEqual(model.workingCount, 1)
        // An ended job leaves the list after a while, like the server drops it.
        let later = Date().addingTimeInterval(MacJob.shownFor + 60)
        model.apply(jobs: [entry("b", status: "done", completedAt: Date().timeIntervalSince1970)], now: later)
        XCTAssertTrue(model.jobs.isEmpty)
    }

    @MainActor
    func testAVoiceJobsAnswerIsReadOutOnceEvenIfTheFeedComesAgain() {
        let model = AppModel()
        var said: [String] = []
        model.onSpeak = { said.append($0.result) }
        let speak = entry(status: "done", completedAt: 1_030, result: "The lease wins.")
        let frame: [String: Any] = ["type": "topic", "topic": "harness_jobs", "data": ["jobs": [speak], "speak": speak]]
        model.handle(frame)
        model.handle(frame)
        XCTAssertEqual(said, ["The lease wins."])
        // Nothing to say, nothing said; a plain feed update never speaks.
        model.handle(["type": "topic", "topic": "harness_jobs",
                      "data": ["jobs": [], "speak": entry("empty", status: "done", completedAt: 1_030)]])
        model.handle(["type": "topic", "topic": "harness_jobs", "data": ["jobs": [entry("c", status: "done", result: "x")]]])
        XCTAssertEqual(said, ["The lease wins."])
        // Read aloud from the tab says it again on purpose.
        model.readAloud(MacJob(json: speak))
        XCTAssertEqual(said.count, 2)
    }
}
