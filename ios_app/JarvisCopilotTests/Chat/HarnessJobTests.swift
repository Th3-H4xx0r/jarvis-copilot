import XCTest
@testable import JarvisCopilot

/// The background-job card under a reply (harness Background jobs): parsing it
/// off `_meta.jobs`, how it reads (the same words as webui/static/harness_jobs.js)
/// and how the chat keeps it live (catch-up, `harness_job` events, Stop).
final class HarnessJobFormatTests: XCTestCase {
    private func job(_ status: String = "running", steps: Int = 0, activity: String = "",
                     completed: Double? = nil) -> HarnessJob {
        HarnessJob(id: "j1", label: "Long Running", model: "@anthropic-api:claude-sonnet-5-5",
                   status: status, startedAt: 1000, completedAt: completed, steps: steps, activity: activity)
    }

    func testParsesOffTheReplysMeta() {
        let meta = HarnessMeta(json: ["model": "@x:y", "jobs": [[
            "id": "j1", "node": "bg", "label": "Long Running", "model": "@anthropic-api:claude-sonnet-5-5",
            "status": "running", "started_at": 1000, "completed_at": NSNull(), "steps": 3,
            "activity": "Searching the web",
        ], ["no": "id"]]])
        XCTAssertEqual(meta?.jobs, [job(steps: 3, activity: "Searching the web")])
        XCTAssertEqual(HarnessMeta(json: ["model": "@x:y"])?.jobs, [])
    }

    func testClockAndDuration() {
        XCTAssertEqual(HarnessJobFormat.clock(0), "0:00")
        XCTAssertEqual(HarnessJobFormat.clock(252), "4:12")
        XCTAssertEqual(HarnessJobFormat.clock(3909), "1:05:09")
        XCTAssertEqual(HarnessJobFormat.duration(42), "42 s")
        XCTAssertEqual(HarnessJobFormat.duration(252), "4m 12s")
        XCTAssertEqual(HarnessJobFormat.duration(3900), "1h 05m")
    }

    func testRunningDetail() {
        XCTAssertEqual(HarnessJobFormat.detail(job(steps: 6, activity: "Searching the web")),
                       "Searching the web · step 6")
        XCTAssertEqual(HarnessJobFormat.detail(job()), "Starting")
    }

    func testEndedLines() {
        XCTAssertEqual(HarnessJobFormat.line(job("done", steps: 18, completed: 1252)),
                       "Long Running · finished in 4m 12s · 18 steps")
        XCTAssertEqual(HarnessJobFormat.line(job("done", steps: 1, completed: 1001)),
                       "Long Running · finished in 1 s · 1 step")
        XCTAssertEqual(HarnessJobFormat.line(job("failed", completed: 1063)),
                       "Long Running · couldn't finish (after 1m 03s)")
        XCTAssertEqual(HarnessJobFormat.line(job("stopped", completed: 1130)),
                       "Long Running · stopped after 2m 10s")
        XCTAssertEqual(HarnessJobFormat.line(job("lost")), "Long Running · stopped when the server restarted")
    }
}

@MainActor
final class ChatStoreJobTests: XCTestCase {
    private var transport: ScriptedTransport!
    private var store: ChatStore!

    override func setUp() {
        super.setUp()
        transport = ScriptedTransport()
        store = ChatStore(api: JarvisAPI(credentials: TestCredentials(), transport: transport),
                          selection: ModelSelection(store: MemoryKeyValueStore()),
                          bus: ChatSyncBus(), clock: ManualChatClock(), onDevice: nil,
                          resilience: ChatResilience(idleLimit: 45, checkStep: 5, maxReattach: 3))
    }

    private func card(_ id: String, status: String = "running", steps: Int = 0) -> [String: Any] {
        ["id": id, "label": "Long Running", "model": "@x:y", "status": status, "started_at": 1000,
         "steps": steps, "activity": ""]
    }

    private func stored(_ id: String) -> HarnessJob {
        HarnessJob(id: id, label: "Long Running", model: "@x:y", status: "running", startedAt: 1000)
    }

    func testOpeningAChatCatchesUpItsRunningJobs() async {
        transport.on("GET /api/session", .json(["session": ["title": "Flights", "messages": [
            ["role": "user", "content": "research flights"],
            ["role": "assistant", "content": "On it.", "_meta": ["model": "@x:y", "jobs": [card("j1"), card("j2")]]],
        ]]]))
        // The server answers for every card: j2 was cut short by a restart.
        transport.on("GET /api/harnesses/jobs/s1", .json(["jobs": [card("j1", steps: 3), card("j2", status: "lost")]]))
        await store.openSession("s1")

        XCTAssertTrue(transport.log.contains("GET /api/harnesses/jobs/s1"))
        XCTAssertEqual(store.job(stored("j1")).steps, 3)
        XCTAssertEqual(store.job(stored("j2")).status, "lost")
    }

    /// A live "running" left over from an event missed while away never beats
    /// the end the reply was saved with.
    func testAnEndedStoredCardIsFinal() {
        store.applyJob(HarnessJob(json: card("j1", steps: 2))!)
        var ended = stored("j1")
        ended.status = "done"
        XCTAssertEqual(store.job(ended).status, "done")
        XCTAssertEqual(store.job(stored("j1")).steps, 2)
    }

    func testAChatWithNoRunningJobsDoesNotAsk() async {
        transport.on("GET /api/session", .json(["session": ["messages": [
            ["role": "assistant", "content": "Done.", "_meta": ["model": "@x:y", "jobs": [card("j1", status: "done")]]],
        ]]]))
        await store.openSession("s1")
        XCTAssertFalse(transport.log.contains("GET /api/harnesses/jobs/s1"))
    }

    func testALiveJobEventUpdatesTheCard() {
        store.applyJob(HarnessJob(json: card("j1", status: "done", steps: 9))!)
        XCTAssertEqual(store.job(stored("j1")).status, "done")
        XCTAssertEqual(store.job(stored("j1")).steps, 9)
    }

    func testALateRunningUpdateNeverRevivesAnEndedCard() {
        store.applyJob(HarnessJob(json: card("j1", status: "done", steps: 9))!)
        store.applyJob(HarnessJob(json: card("j1", steps: 4))!)
        XCTAssertEqual(store.job(stored("j1")).status, "done")
        store.applyJob(HarnessJob(json: card("j2", status: "lost"))!)
        store.applyJob(HarnessJob(json: card("j2", steps: 1))!)
        XCTAssertEqual(store.job(stored("j2")).status, "lost")
    }

    func testAJobBeingStoppedSaysSo() {
        var json = card("j1")
        json["stopping"] = true
        XCTAssertEqual(HarnessJob(json: json)?.stopping, true)
        XCTAssertEqual(HarnessJob(json: card("j1"))?.stopping, false)
    }

    func testStopAsksTheServer() async {
        transport.on("GET /api/session", .json(["session": ["messages": []]]))
        await store.openSession("s1")
        transport.on("POST /api/harnesses/jobs/s1/j1/stop", .json(["ok": true]))
        await store.stopJob("j1")
        XCTAssertTrue(transport.log.contains("POST /api/harnesses/jobs/s1/j1/stop"))
    }
}
