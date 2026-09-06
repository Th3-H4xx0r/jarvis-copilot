import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/crons_test.dart`, case for case. The Dart
/// colour assertions become `MoreTone` assertions (this layer is view-free).
final class CronsTests: XCTestCase {

    // MARK: cronJobId

    func testPrefersJobIDOverID() {
        XCTAssertEqual(Crons.jobID(["job_id": "abc", "id": "xyz"]), "abc")
    }

    func testFallsBackToID() {
        XCTAssertEqual(Crons.jobID(["id": "xyz"]), "xyz")
    }

    func testEmptyWhenNeitherPresent() {
        XCTAssertEqual(Crons.jobID([:]), "")
    }

    // MARK: cronStatusKey

    func testFlatStatusStringWins() {
        XCTAssertEqual(Crons.statusKey(["status": "Running"]), "running")
    }

    func testPausedState() {
        XCTAssertEqual(Crons.statusKey(["state": "paused", "enabled": true]), "paused")
    }

    func testDisabledBecomesOff() {
        XCTAssertEqual(Crons.statusKey(["state": "scheduled", "enabled": false]), "off")
    }

    func testLastStatusErrorBecomesError() {
        XCTAssertEqual(Crons.statusKey([
            "state": "scheduled",
            "enabled": true,
            "last_status": "error",
            "next_run_at": "2026-01-01T00:00:00",
        ]), "error")
    }

    func testErrorWithNoNextRunBecomesNeedsAttention() {
        XCTAssertEqual(Crons.statusKey(["state": "error", "enabled": true]), "needs_attention")
    }

    func testDefaultScheduledStaysScheduled() {
        XCTAssertEqual(Crons.statusKey(["state": "scheduled", "enabled": true]), "scheduled")
    }

    func testEmptyJobBecomesActive() {
        XCTAssertEqual(Crons.statusKey([:]), "active")
    }

    // MARK: cronStatusLabel

    func testKnownStatusKeys() {
        XCTAssertEqual(Crons.statusLabel("running"), "RUNNING")
        XCTAssertEqual(Crons.statusLabel("paused"), "PAUSED")
        XCTAssertEqual(Crons.statusLabel("off"), "OFF")
        XCTAssertEqual(Crons.statusLabel("error"), "ERROR")
        XCTAssertEqual(Crons.statusLabel("needs_attention"), "NEEDS ATTENTION")
        XCTAssertEqual(Crons.statusLabel("scheduled"), "ACTIVE")
        XCTAssertEqual(Crons.statusLabel("active"), "ACTIVE")
    }

    func testUnknownStatusKeyUppercases() {
        XCTAssertEqual(Crons.statusLabel("whatever"), "WHATEVER")
    }

    func testEmptyStatusKeyDefaultsToActive() {
        XCTAssertEqual(Crons.statusLabel(""), "ACTIVE")
    }

    // MARK: cronStatusColor → cronStatusTone

    func testRunningIsPrimaryBlue() {
        XCTAssertEqual(Crons.statusTone("running"), .primaryBlue)
    }

    func testPausedIsMuted() {
        XCTAssertEqual(Crons.statusTone("paused"), .muted)
        XCTAssertEqual(Crons.statusTone("off"), .muted)
        XCTAssertEqual(Crons.statusTone("completed"), .muted)
    }

    func testErrorAndNeedsAreDanger() {
        XCTAssertEqual(Crons.statusTone("error"), .danger)
        XCTAssertEqual(Crons.statusTone("needs_attention"), .danger)
    }

    func testDefaultToneIsSuccess() {
        XCTAssertEqual(Crons.statusTone("scheduled"), .success)
        XCTAssertEqual(Crons.statusTone("anything"), .success)
    }

    // MARK: cronIsPaused

    func testTrueForPausedState() {
        XCTAssertTrue(Crons.isPaused(["state": "paused"]))
    }

    func testFalseOtherwise() {
        XCTAssertFalse(Crons.isPaused(["state": "scheduled", "enabled": true]))
    }

    // MARK: cronSchedule

    func testPrefersScheduleDisplay() {
        XCTAssertEqual(Crons.schedule(["schedule_display": "every day",
                                       "schedule": JSONObject()]), "every day")
    }

    func testFlatStringSchedule() {
        XCTAssertEqual(Crons.schedule(["schedule": "*/5 * * * *"]), "*/5 * * * *")
    }

    func testDictScheduleWithExpression() {
        XCTAssertEqual(Crons.schedule(["schedule": ["expression": "0 9 * * *"]]), "0 9 * * *")
    }

    func testEmptyWhenNothingUsable() {
        XCTAssertEqual(Crons.schedule([:]), "")
    }

    // MARK: formatCronTime

    func testFormatTimeRelativeWithinTheHourAndDay() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(Crons.formatTime(now.timeIntervalSince1970, now: now), "now")
        XCTAssertEqual(Crons.formatTime(now.timeIntervalSince1970 + 240, now: now), "in 4m")
        XCTAssertEqual(Crons.formatTime(now.timeIntervalSince1970 - 7200, now: now), "2h ago")
    }

    /// The absolute fallback is hand-rolled against `Calendar.current` (so the
    /// string never shifts with the device LOCALE), which leaves the device
    /// TIME ZONE as the only variable. Pinning a fixed calendar here asserts the
    /// exact string instead of a shape a wrong month or hour would still match.
    func testFormatTimeFallsBackToAnAbsoluteLocalString() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let target = now.addingTimeInterval(86400 * 3)
        let out = Crons.formatTime(target.timeIntervalSince1970, now: now)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: target)
        let hour24 = c.hour!
        let expected = String(format: "%@ %d, %d:%02d %@",
                              RelativeTime.months[c.month! - 1], c.day!,
                              hour24 % 12 == 0 ? 12 : hour24 % 12, c.minute!,
                              hour24 < 12 ? "AM" : "PM")
        XCTAssertEqual(out, expected)
    }

    /// Locale-independent by construction: switching the process locale must not
    /// move the month name or flip to a 24-hour clock.
    func testTheAbsoluteFallbackIgnoresTheDeviceLocale() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let out = Crons.formatTime(now.timeIntervalSince1970 + 86400 * 3, now: now)
        XCTAssertTrue(out.hasSuffix(" AM") || out.hasSuffix(" PM"),
                      "hand-rolled 12-hour clock, not DateFormatter: \(out)")
        XCTAssertTrue(RelativeTime.months.contains { out.hasPrefix($0 + " ") },
                      "an English 3-letter month, whatever the locale: \(out)")
    }

    func testFormatTimeEmptyAndUnparseableInputs() {
        XCTAssertEqual(Crons.formatTime(nil), "")
        XCTAssertEqual(Crons.formatTime(""), "")
        XCTAssertEqual(Crons.formatTime("never"), "never")
    }

    // MARK: Job + run models

    func testJobDefaultsDeliverToLocalAndToastsToOn() {
        let job = CronJob(json: ["id": "j1", "prompt": "do it"])
        XCTAssertEqual(job.id, "j1")
        XCTAssertEqual(job.deliver, "local")
        XCTAssertTrue(job.toastNotifications)
        XCTAssertEqual(job.title, "do it")
        XCTAssertEqual(job.statusKey, "active")
    }

    func testDeliverLabelsAndIcons() {
        XCTAssertEqual(CronDeliver.options, ["local", "origin", "telegram", "discord", "slack"])
        XCTAssertEqual(CronDeliver.label("local"), "In-app only")
        XCTAssertEqual(CronDeliver.label("origin"), "Originating chat")
        XCTAssertEqual(CronDeliver.label("custom"), "Custom")
        XCTAssertEqual(CronDeliver.label(""), "—")
        XCTAssertEqual(CronDeliver.iconName("slack"), "number")
    }

    func testRunLabelCleansTheFilenameAndFallsBack() {
        let named = CronRun(json: ["filename": "2026-06-22_0930.md", "size": 2048], index: 0)
        XCTAssertEqual(named.label, "2026-06-22 0930")
        XCTAssertEqual(named.subtitle, "2.0 KB")
        XCTAssertEqual(named.id, "2026-06-22_0930.md")

        let stamped = CronRun(json: ["ts": "2026-06-22T09:30:00Z"], index: 3)
        XCTAssertEqual(stamped.label, "2026-06-22T09:30:00Z")
        XCTAssertEqual(stamped.id, "run_3")
        XCTAssertNil(stamped.subtitle)

        let bare = CronRun(json: [:], index: 1)
        XCTAssertEqual(bare.label, "Run")
    }

    // MARK: API requests

    func testListReadsTheJobsEnvelope() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["jobs": [["id": "j1", "name": "Nightly"]]])
        let jobs = try await CronsAPI(api: api).list()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/crons")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(jobs.map(\.name), ["Nightly"])
    }

    func testHistoryReadsRunsAndToleratesEntries() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["runs": [["filename": "a.md"], ["filename": "b.md"]]])
        var runs = try await CronsAPI(api: api).history("j1", limit: 10)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/crons/history")
        XCTAssertEqual(transport.lastQuery, ["job_id": "j1", "limit": "10"])
        XCTAssertEqual(runs.map(\.filename), ["a.md", "b.md"])

        transport.enqueue(json: ["entries": [["filename": "legacy.md"]]])
        runs = try await CronsAPI(api: api).history("j1")
        XCTAssertEqual(runs.map(\.filename), ["legacy.md"])
        XCTAssertEqual(transport.lastQuery, ["job_id": "j1", "limit": "50"])
    }

    func testOutputJoinsTheOutputsListWithFilenameHeaders() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["outputs": [
            ["filename": "a.md", "content": "first"],
            ["content": "second"],
            ["filename": "empty.md", "content": "   "],
        ]])
        let out = try await CronsAPI(api: api).output("j1", tail: 50)

        XCTAssertEqual(transport.lastPath, "/api/crons/output")
        XCTAssertEqual(transport.lastQuery, ["job_id": "j1", "tail": "50"])
        XCTAssertEqual(out, "— a.md —\nfirst\n\nsecond")
    }

    func testOutputPrefersAPlainOutputStringAndToleratesLines() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["output": "plain text"])
        var out = try await CronsAPI(api: api).output("j1")
        XCTAssertEqual(out, "plain text")

        transport.enqueue(json: ["lines": ["a", "b"]])
        out = try await CronsAPI(api: api).output("j1")
        XCTAssertEqual(out, "a\nb")

        transport.enqueue(json: ["other": 1])
        out = try await CronsAPI(api: api).output("j1")
        XCTAssertEqual(out, "")
    }

    func testRunOutputReadsContentThenOutputThenLines() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["content": "run body"])
        let out = try await CronsAPI(api: api).runOutput("j1", filename: "a.md")

        XCTAssertEqual(transport.lastPath, "/api/crons/run")
        XCTAssertEqual(transport.lastQuery, ["job_id": "j1", "filename": "a.md"])
        XCTAssertEqual(out, "run body")

        transport.enqueue(json: ["lines": ["x", "y"]])
        let lines = try await CronsAPI(api: api).runOutput("j1", filename: "b.md")
        XCTAssertEqual(lines, "x\ny")
    }

    func testMutationEndpointsPostJobID() async throws {
        let (api, transport) = JarvisAPI.mocked()
        for (call, path) in [("delete", "/api/crons/delete"), ("run", "/api/crons/run"),
                             ("pause", "/api/crons/pause"), ("resume", "/api/crons/resume")] {
            transport.enqueue(json: ["ok": true])
            switch call {
            case "delete": try await CronsAPI(api: api).delete("j1")
            case "run": try await CronsAPI(api: api).run("j1")
            case "pause": try await CronsAPI(api: api).pause("j1")
            default: try await CronsAPI(api: api).resume("j1")
            }
            XCTAssertEqual(transport.lastMethod, "POST", path)
            XCTAssertEqual(transport.lastPath, path)
            assertJSONEqual(transport.lastBody(), ["job_id": "j1"], path)
        }
    }

    func testCreateAndUpdatePostTheWholeBody() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await CronsAPI(api: api).create(["prompt": "p", "schedule": "s"])
        XCTAssertEqual(transport.lastPath, "/api/crons/create")
        assertJSONEqual(transport.lastBody(), ["prompt": "p", "schedule": "s"])

        transport.enqueue(json: ["ok": true])
        try await CronsAPI(api: api).update(["job_id": "j1", "prompt": "p2"])
        XCTAssertEqual(transport.lastPath, "/api/crons/update")
        assertJSONEqual(transport.lastBody(), ["job_id": "j1", "prompt": "p2"])
    }

    // MARK: Store

    @MainActor
    func testStoreHarvestsSkillsAndDetectsRunning() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons", json: ["jobs": [
            ["id": "j1", "state": "running", "enabled": true, "skills": ["notify", "web"]],
            ["id": "j2", "state": "scheduled", "enabled": true, "skills": ["notify"]],
        ]])

        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()

        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertTrue(store.anyRunning)
        XCTAssertEqual(store.skillOptions(), ["notify", "web"])
        XCTAssertEqual(store.skillOptions(including: ["zeta"]), ["notify", "web", "zeta"])
        XCTAssertTrue(store.isPolling)
        store.onDisappear()
        XCTAssertFalse(store.isPolling)
    }

    @MainActor
    func testStoreDoesNotPollWhenNothingIsRunning() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons", json: ["jobs": [["id": "j1", "state": "scheduled",
                                                       "enabled": true]]])
        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        await store.refresh()
        XCTAssertFalse(store.anyRunning)
        XCTAssertFalse(store.isPolling)
    }

    @MainActor
    func testStoreSaveDropsBlankOptionalsAndKeepsRequiredFields() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/create", json: ["ok": true])
        transport.route("/api/crons", json: ["jobs": []])

        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        let ok = await store.save(prompt: " do it ", schedule: " every day ", name: "   ",
                                  deliver: "local", skills: ["notify"], model: "  ",
                                  profile: "coder", toastNotifications: false)

        XCTAssertTrue(ok)
        assertJSONEqual(transport.body(0), [
            "prompt": "do it", "schedule": "every day", "deliver": "local",
            "skills": ["notify"], "toast_notifications": false, "profile": "coder",
        ])
    }

    @MainActor
    func testStoreSaveWithAnExistingJobUpdatesAndCarriesJobID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/update", json: ["ok": true])
        transport.route("/api/crons", json: ["jobs": []])

        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        let existing = CronJob(json: ["id": "j9", "prompt": "old"])
        let ok = await store.save(prompt: "new", schedule: "s", name: "N", deliver: "slack",
                                  skills: [], model: "", profile: "",
                                  toastNotifications: true, existing: existing)

        XCTAssertTrue(ok)
        XCTAssertEqual(transport.path(0), "/api/crons/update")
        assertJSONEqual(transport.body(0), [
            "job_id": "j9", "prompt": "new", "schedule": "s", "name": "N",
            "deliver": "slack", "skills": [String](), "toast_notifications": true,
        ])
    }

    @MainActor
    func testStoreRunShowsAStartingSpinnerThenRefreshes() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/run", json: ["ok": true])
        transport.route("/api/crons", json: ["jobs": []])

        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        let job = CronJob(json: ["id": "j1"])
        await store.run(job)

        XCTAssertEqual(store.toast, "Run started")
        XCTAssertFalse(store.isStarting(job))
        XCTAssertEqual(transport.path(0), "/api/crons/run")
        store.onDisappear()
    }

    @MainActor
    func testStoreTogglePauseChoosesResumeForAPausedJob() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/resume", json: ["ok": true])
        transport.route("/api/crons", json: ["jobs": []])

        let store = CronsStore(api: CronsAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
        await store.togglePause(CronJob(json: ["id": "j1", "state": "paused"]))

        XCTAssertEqual(transport.path(0), "/api/crons/resume")
        XCTAssertEqual(store.toast, "Task resumed")
    }

    @MainActor
    func testHistoryStoreLazyLoadsEachRunOutputOnce() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/history", json: ["runs": [["filename": "a.md"]]])
        transport.route("/api/crons/run", json: ["content": "output body"])

        let store = CronHistoryStore(api: CronsAPI(api: api), jobID: "j1")
        await store.load()
        XCTAssertEqual(store.runs.map(\.id), ["a.md"])

        let run = store.runs[0]
        await store.loadOutput(run)
        XCTAssertEqual(store.output(for: run), "output body")

        let requestsAfterFirst = transport.requests.count
        await store.loadOutput(run)
        XCTAssertEqual(transport.requests.count, requestsAfterFirst, "must not refetch")
    }

    @MainActor
    func testHistoryStoreRecordsAFailedOutputInline() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/crons/history", json: ["runs": [["filename": "a.md"]]])
        transport.route("/api/crons/run", json: ["error": "gone"], status: 404)

        let store = CronHistoryStore(api: CronsAPI(api: api), jobID: "j1")
        await store.load()
        await store.loadOutput(store.runs[0])
        XCTAssertEqual(store.output(for: store.runs[0]), "Failed to load output: gone")
    }
}
