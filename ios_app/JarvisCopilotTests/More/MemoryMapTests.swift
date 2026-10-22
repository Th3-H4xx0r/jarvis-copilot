import Foundation
import XCTest
@testable import JarvisCopilot

/// The Long-term Memory page's memory model setting and the Cleanup card.
@MainActor
final class MemoryMapTests: XCTestCase {

    private static let report: JSONObject = [
        "started_at": 1_790_000_000, "finished_at": 1_790_000_300, "backup": "/tmp/backup.db",
        "counts": ["merged": 4, "hidden_trivial": 7, "superseded": 2, "live_rewritten": 3,
                   "restamped": 5, "enriched": 40, "failed": 0],
        "examples": [
            "merged": [["id": "m1", "body": "Likes oat milk"]],
            "hidden_trivial": [["id": "h1", "body": "Said ok"], ["id": "h2", "body": "Said thanks"]],
            "superseded": [["id": "s1", "body": "Lives in Leeds"]],
        ],
    ]

    // MARK: Parsing

    func testARunningCleanupReadsItsProgress() {
        let status = MemoryCleanupStatus(json: [
            "running": true, "progress": ["step": "Merging", "done": 3, "total": 10], "report": NSNull(),
        ])
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.progress, MemoryCleanupProgress(step: "Merging", done: 3, total: 10))
        XCTAssertNil(status.report)
    }

    func testTheLastReportReadsCountsInOrderAndItsExamples() throws {
        let status = MemoryCleanupStatus(json: ["running": false, "progress": NSNull(), "report": Self.report])
        let report = try XCTUnwrap(status.report)
        XCTAssertEqual(report.counts.map(\.label),
                       ["Merged duplicates", "Hidden trivia", "Marked out of date",
                        "Live rewritten", "Times fixed", "Mapped"],
                       "failed only shows when something failed")
        XCTAssertEqual(report.counts.map(\.value), [4, 7, 2, 3, 5, 40])
        XCTAssertEqual(report.examples.map(\.kind), [.merged, .hiddenTrivial, .superseded])
        XCTAssertEqual(report.examples[1].items.map(\.id), ["h1", "h2"])
        XCTAssertEqual(report.examples[1].items.first?.body, "Said ok")
        XCTAssertNotNil(report.finishedAt)
    }

    func testStepsReadAsPlainEnglish() {
        let steps = ["backup": "Backing up", "live": "Rewriting Live", "stamps": "Fixing times",
                     "duplicates": "Merging duplicates", "map": "Mapping memories", "starting": "Starting"]
        for (key, name) in steps {
            XCTAssertEqual(MemoryCleanupProgress(step: key, done: 0, total: 0).line, name)
        }
        XCTAssertEqual(MemoryCleanupProgress(step: "duplicates", done: 3, total: 10).line,
                       "Merging duplicates · 3/10")
        XCTAssertEqual(MemoryCleanupProgress(step: "something_new", done: 0, total: 0).line, "something_new",
                       "a step the app doesn't know yet still shows")
    }

    func testAMissingOrEmptyStatusIsNotRunning() {
        let status = MemoryCleanupStatus(json: [:])
        XCTAssertFalse(status.running)
        XCTAssertNil(status.progress)
        XCTAssertNil(status.report)
    }

    // MARK: Memory model

    func testTheMemoryModelLoadsAndSaves() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/map-settings") { request in
            let body: JSONObject = request.httpMethod == "POST"
                ? ["agent": ["model": "claude-haiku-5-5", "provider": NSNull()], "label": "Haiku 5.5"]
                : ["agent": ["harness_id": "fast"], "label": "Fast"]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: body))
        }
        transport.route("/api/jarvis-memory/cleanup/status", json: ["running": false])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })

        await store.load()
        XCTAssertEqual(store.settings?.agent, .harness("fast"))
        XCTAssertEqual(store.settings?.label, "Fast")

        await store.setAgent(.model(id: "claude-haiku-5-5", provider: nil))
        let post = try XCTUnwrap(transport.requests.last { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/api/jarvis-memory/map-settings")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? JSONObject)
        let agent = try XCTUnwrap(body["agent"] as? JSONObject)
        XCTAssertEqual(agent["model"] as? String, "claude-haiku-5-5")
        XCTAssertTrue(agent["provider"] is NSNull)
        XCTAssertEqual(store.settings?.label, "Haiku 5.5", "the server's label for what it resolved")
    }

    /// While a save is in flight a reload must not put the old model back, and
    /// the row must not show the old model's label next to the new pick.
    func testAReloadDuringASaveKeepsTheNewPick() async throws {
        let transport = MockTransport()
        let gated = PostGatedTransport(inner: transport)
        let api = JarvisAPI(credentials: TestCredentials(), transport: gated)
        transport.route("/api/jarvis-memory/map-settings") { request in
            let body: JSONObject = request.httpMethod == "POST"
                ? ["agent": ["harness_id": "new"], "label": "New"]
                : ["agent": ["harness_id": "old"], "label": "Old"]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: body))
        }
        transport.route("/api/jarvis-memory/cleanup/status", json: ["running": false])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        await store.load()
        XCTAssertEqual(store.settings?.label, "Old")

        let saving = Task { await store.setAgent(.harness("new")) }
        await servicesWaitUntil { gated.parked }
        XCTAssertTrue(gated.parked)
        XCTAssertEqual(store.settings?.agent, .harness("new"))
        XCTAssertEqual(store.settings?.label, "", "the old model's label is gone")

        await store.load()
        XCTAssertEqual(store.settings?.agent, .harness("new"), "a reload mid-save doesn't undo the pick")

        gated.open()
        await saving.value
        XCTAssertEqual(store.settings?.label, "New")
    }

    func testSameAsDefaultPostsNull() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/map-settings", json: ["agent": NSNull(), "label": "Default"])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })

        await store.setAgent(nil)
        XCTAssertTrue(transport.lastBody()["agent"] is NSNull)
        XCTAssertNil(store.settings?.agent)
    }

    // MARK: Cleanup

    func testRunningCleanupPollsUntilItFinishes() async {
        let (api, transport) = JarvisAPI.mocked()
        var polls = 0
        let report = Self.report
        transport.route("/api/jarvis-memory/cleanup/status") { _ in
            polls += 1
            let body: JSONObject = polls < 3
                ? ["running": true, "progress": ["step": "Merging", "done": polls, "total": 3]]
                : ["running": false, "report": report]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: body))
        }
        transport.route("/api/jarvis-memory/cleanup/start", json: ["ok": true, "started": true])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        store.appeared()

        await store.runCleanup()
        await servicesWaitUntil { store.cleanup?.running == false && store.cleanup?.report != nil }

        XCTAssertTrue(transport.paths.contains("/api/jarvis-memory/cleanup/start"))
        XCTAssertEqual(store.cleanup?.report?.counts.first?.value, 4)
        let settled = transport.requests.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, settled, "polling stops once it's done")
    }

    func testPollingStopsWhenThePageGoesAway() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/cleanup/status",
                        json: ["running": true, "progress": ["step": "Merging", "done": 1, "total": 9]])
        transport.route("/api/jarvis-memory/cleanup/start", json: ["ok": true, "started": true])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api),
                                   sleeper: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        store.appeared()
        await store.runCleanup()
        store.disappeared()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let settled = transport.requests.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, settled)
    }

    /// Locking the phone or leaving the app stops the 3 s poll even with the page
    /// still on top; coming back picks it up again.
    func testPollingPausesInTheBackgroundAndResumes() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/cleanup/status",
                        json: ["running": true, "progress": ["step": "map", "done": 1, "total": 9]])
        transport.route("/api/jarvis-memory/cleanup/start", json: ["ok": true, "started": true])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api),
                                   sleeper: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        store.appeared()
        await store.runCleanup()

        store.setActive(false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let settled = transport.requests.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, settled, "no polling in the background")

        store.setActive(true)
        await servicesWaitUntil { transport.requests.count >= settled + 2 }
        XCTAssertGreaterThanOrEqual(transport.requests.count, settled + 2, "polling resumes")
        store.disappeared()
    }

    // MARK: Stop

    func testStoppingReadsFromTheStatus() {
        let stopping = MemoryCleanupStatus(json: ["running": true, "stopping": true])
        XCTAssertTrue(stopping.stopping)
        XCTAssertFalse(stopping.canStop, "the Stop button is disabled while it stops")
        XCTAssertEqual(stopping.stopTitle, "Stopping…")
        let running = MemoryCleanupStatus(json: ["running": true])
        XCTAssertFalse(running.stopping, "an older server without the key is not stopping")
        XCTAssertTrue(running.canStop)
        XCTAssertEqual(running.stopTitle, "Stop")
    }

    func testTheRunButtonReadsRunAgainAfterAReport() {
        XCTAssertEqual(MemoryCleanupStatus(json: ["running": false]).runTitle, "Run cleanup")
        XCTAssertEqual(MemoryCleanupStatus(json: ["running": false, "report": Self.report]).runTitle, "Run again")
    }

    func testStopPostsAndShowsStopping() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var stopped = false
        transport.route("/api/jarvis-memory/cleanup/stop") { _ in
            stopped = true
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: ["ok": true]))
        }
        transport.route("/api/jarvis-memory/cleanup/status") { _ in
            let body: JSONObject = ["running": true, "stopping": stopped,
                                    "progress": ["step": "map", "done": 2, "total": 9]]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: body))
        }
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api),
                                   sleeper: { _ in try await Task.sleep(nanoseconds: 50_000_000) })
        await store.load()
        XCTAssertEqual(store.cleanup?.canStop, true)

        await store.stopCleanup()
        let stop = try XCTUnwrap(transport.requests.firstIndex { $0.url?.path == "/api/jarvis-memory/cleanup/stop" })
        XCTAssertEqual(transport.method(stop), "POST")
        assertJSONEqual(transport.body(stop), [:])
        XCTAssertEqual(store.cleanup?.stopping, true)
        XCTAssertEqual(store.cleanup?.canStop, false)
        store.disappeared()
    }

    func testAStopFailureIsShownAndTheButtonComesBack() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/cleanup/stop", json: ["error": "nope"], status: 500)
        transport.route("/api/jarvis-memory/cleanup/status", json: ["running": true])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        await store.load()
        await store.stopCleanup()
        XCTAssertNotNil(store.toast)
        XCTAssertFalse(store.requestingStop)
        XCTAssertEqual(store.cleanup?.canStop, true)
    }

    /// A run the server started itself (the shell backfill) shows its progress
    /// and is polled with no Run tap on this phone.
    func testARunStartedElsewhereIsFollowed() async {
        let (api, transport) = JarvisAPI.mocked()
        var polls = 0
        transport.route("/api/jarvis-memory/cleanup/status") { _ in
            polls += 1
            let body: JSONObject = polls < 3
                ? ["running": true, "progress": ["step": "map", "done": polls, "total": 3]]
                : ["running": false, "report": Self.report]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: body))
        }
        transport.route("/api/jarvis-memory/map-settings", json: ["agent": NSNull(), "label": "Default"])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        store.appeared()
        await servicesWaitUntil { store.cleanup?.report != nil }
        XCTAssertEqual(store.cleanup?.running, false)
        XCTAssertFalse(transport.paths.contains("/api/jarvis-memory/cleanup/start"))
        XCTAssertGreaterThanOrEqual(polls, 3)
    }

    func testRestorePostsTheIdMarksTheRowAndRefreshes() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/cleanup/restore", json: ["ok": true, "restored": 1])
        transport.route("/api/jarvis-memory/cleanup/status", json: ["running": false])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })

        await store.restore("h1")

        XCTAssertEqual(transport.paths, ["/api/jarvis-memory/cleanup/restore", "/api/jarvis-memory/cleanup/status"])
        XCTAssertEqual(transport.body(0)["ids"] as? [String], ["h1"])
        XCTAssertTrue(store.restored.contains("h1"))
    }
}

/// Holds every POST until `open()`, suspending (never blocking a thread) so the
/// store can be poked while a save is on the wire.
private final class PostGatedTransport: APITransport, @unchecked Sendable {
    let inner: MockTransport
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(inner: MockTransport) { self.inner = inner }

    var parked: Bool { lock.lock(); defer { lock.unlock() }; return !waiters.isEmpty }

    func open() {
        lock.lock()
        isOpen = true
        let parked = waiters
        waiters = []
        lock.unlock()
        parked.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "POST" {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
        return try await inner.send(request)
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await inner.stream(request)
    }
}
