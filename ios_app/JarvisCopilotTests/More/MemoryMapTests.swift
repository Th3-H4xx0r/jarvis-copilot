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

    func testRestorePostsTheIdAndMarksTheRow() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/cleanup/restore", json: ["ok": true, "restored": 1])
        let store = MemoryMapStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })

        await store.restore("h1")

        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/cleanup/restore")
        XCTAssertEqual(transport.lastBody()["ids"] as? [String], ["h1"])
        XCTAssertTrue(store.restored.contains("h1"))
    }
}
