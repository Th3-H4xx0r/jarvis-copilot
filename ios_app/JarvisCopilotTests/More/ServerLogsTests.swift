import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/server_logs_test.dart`, case for case, plus
/// the filter/auto-refresh behaviour from `server_logs_page.dart`.
final class ServerLogsTests: XCTestCase {

    // MARK: logSeverity

    func testAnErrorLineIsError() {
        XCTAssertEqual(logSeverity("2026-06-21 ERROR something blew up"), .error)
        XCTAssertEqual(logSeverity("Traceback (most recent call last):"), .error)
        XCTAssertEqual(logSeverity("raised an Exception"), .error)
        XCTAssertEqual(logSeverity("CRITICAL failure"), .error)
        // Case-insensitive.
        XCTAssertEqual(logSeverity("an error occurred"), .error)
    }

    func testAWarningLineIsWarn() {
        XCTAssertEqual(logSeverity("2026-06-21 WARNING low disk"), .warn)
        XCTAssertEqual(logSeverity("WARN: retrying"), .warn)
        XCTAssertEqual(logSeverity("a warning was issued"), .warn)
    }

    func testAPlainOrInfoLineIsInfo() {
        XCTAssertEqual(logSeverity("INFO server started"), .info)
        XCTAssertEqual(logSeverity("just a plain line"), .info)
        XCTAssertEqual(logSeverity(""), .info)
    }

    // MARK: parseLogLines

    func testFromLinesArray() {
        XCTAssertEqual(parseLogLines(["lines": ["a", "b", "c"]] as JSONObject), ["a", "b", "c"])
    }

    func testFromContentString() {
        XCTAssertEqual(parseLogLines(["content": "a\nb"] as JSONObject), ["a", "b"])
    }

    func testContentWithTrailingNewlineDropsTheEmptyFinalLine() {
        XCTAssertEqual(parseLogLines(["content": "a\nb\n"] as JSONObject), ["a", "b"])
    }

    func testBareList() {
        XCTAssertEqual(parseLogLines(["x", "y"]), ["x", "y"])
    }

    func testMissingOrUnknownShapeYieldsEmpty() {
        XCTAssertTrue(parseLogLines(["nope": 1] as JSONObject).isEmpty)
        XCTAssertTrue(parseLogLines(42).isEmpty)
        XCTAssertTrue(parseLogLines(nil).isEmpty)
    }

    func testServerLogFilesMatchesTheBackendWhitelist() {
        XCTAssertEqual(serverLogFiles, ["agent", "errors", "gateway"])
    }

    // MARK: Filter modes

    func testSeverityFilterAdmission() {
        XCTAssertTrue(LogSeverityFilter.all.admits(.info))
        XCTAssertTrue(LogSeverityFilter.all.admits(.error))
        XCTAssertTrue(LogSeverityFilter.warnings.admits(.warn))
        XCTAssertTrue(LogSeverityFilter.warnings.admits(.error))
        XCTAssertFalse(LogSeverityFilter.warnings.admits(.info))
        XCTAssertTrue(LogSeverityFilter.errors.admits(.error))
        XCTAssertFalse(LogSeverityFilter.errors.admits(.warn))
    }

    func testSeverityTones() {
        XCTAssertEqual(LogSeverity.error.tone, .danger)
        XCTAssertEqual(LogSeverity.warn.tone, .blue)
        XCTAssertEqual(LogSeverity.info.tone, .muted)
    }

    // MARK: Tail payload

    func testTailFallsBackToTheRequestedFileAndSize() {
        let tail = ServerLogTail(json: ["lines": ["a"]], requestedFile: "errors", requestedTail: 250)
        XCTAssertEqual(tail.file, "errors")
        XCTAssertEqual(tail.tail, 250)
        XCTAssertEqual(tail.lines, ["a"])
        XCTAssertFalse(tail.truncated)
        XCTAssertEqual(tail.totalBytes, 0)
        XCTAssertNil(tail.mtime)
        XCTAssertEqual(tail.hint, "")
    }

    func testTailReadsTheServerMetadata() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let tail = ServerLogTail(json: [
            "file": "gateway", "tail": "500", "lines": ["a", "b"],
            "truncated": true, "total_bytes": 4096,
            "mtime": now.timeIntervalSince1970 - 300, "hint": "rotated",
        ], requestedFile: "agent", requestedTail: 1000)
        XCTAssertEqual(tail.file, "gateway")
        XCTAssertEqual(tail.tail, 500)
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.totalBytes, 4096)
        XCTAssertEqual(tail.sizeLabel, "4.0 KB")
        XCTAssertEqual(tail.mtimeLabel(now: now), "5m ago")
        XCTAssertEqual(tail.hint, "rotated")
    }

    // MARK: API requests

    func testTailSendsFileAndTail() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["file": "errors", "tail": 200, "lines": ["boom"]])
        let tail = try await ServerLogsAPI(api: api).tail(file: "errors", tail: 200)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/logs")
        XCTAssertEqual(transport.lastQuery, ["file": "errors", "tail": "200"])
        XCTAssertEqual(tail.lines, ["boom"])
    }

    func testTailDefaultsMatchTheFlutterClient() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["lines": []])
        _ = try await ServerLogsAPI(api: api).tail()
        XCTAssertEqual(transport.lastQuery, ["file": "agent", "tail": "1000"])
    }

    // MARK: Store

    @MainActor
    func testStoreRendersNewestFirstAndFiltersBySeverity() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["lines": [
            "INFO started", "WARNING low disk", "ERROR blew up",
        ]])

        let store = ServerLogsStore(api: ServerLogsAPI(api: api),
                                    refreshInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()

        XCTAssertEqual(store.displayLines, ["ERROR blew up", "WARNING low disk", "INFO started"])
        XCTAssertEqual(store.countLabel, "3 of 3 lines")

        store.filter = .warnings
        XCTAssertEqual(store.displayLines, ["ERROR blew up", "WARNING low disk"])
        XCTAssertEqual(store.countLabel, "2 of 3 lines")

        store.filter = .errors
        XCTAssertEqual(store.filteredLines, ["ERROR blew up"])
        XCTAssertEqual(store.copyText, "ERROR blew up")
        XCTAssertFalse(store.isEmpty)
    }

    @MainActor
    func testStoreIsEmptyWhenTheFilterMatchesNothing() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["lines": ["INFO fine"]])

        let store = ServerLogsStore(api: ServerLogsAPI(api: api),
                                    refreshInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()
        store.filter = .errors
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.copyText, "")
    }

    @MainActor
    func testStoreChangingFileOrTailReloads() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["lines": ["x"]])

        let store = ServerLogsStore(api: ServerLogsAPI(api: api),
                                    refreshInterval: 0.01, sleeper: instantSleeper)
        store.file = "gateway"
        store.tailSize = 500
        await store.refresh()

        XCTAssertEqual(transport.lastQuery, ["file": "gateway", "tail": "500"])
        XCTAssertEqual(ServerLogsStore.tailOptions, [200, 500, 1000, 2000, 5000])
    }

    @MainActor
    func testStoreAutoRefreshArmsAndDisarms() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["lines": ["x"]])

        let store = ServerLogsStore(api: ServerLogsAPI(api: api),
                                    refreshInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()
        let before = transport.requests.count

        store.autoRefresh = true
        for _ in 0..<10 where transport.requests.count == before { await Task.yield() }
        XCTAssertGreaterThan(transport.requests.count, before)

        store.autoRefresh = false
        store.onDisappear()
    }

    @MainActor
    func testStoreSurfacesAnError() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["error": "no such file"], status: 400)

        let store = ServerLogsStore(api: ServerLogsAPI(api: api),
                                    refreshInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()
        XCTAssertEqual(store.errorMessage, "no such file")
    }
}
