import Foundation
import XCTest
@testable import JarvisCopilot

/// `live_activity/live_activity_coordinator.dart`: the fleet encoding, the mode
/// selection, the dedupe and the settings toggle.
@MainActor
final class LiveActivityTests: XCTestCase {

    // MARK: - Fixtures

    private func session(_ id: String, status: String = "running",
                         activity: String? = nil, cwd: String? = nil,
                         source: String? = nil, attached: Bool = true,
                         lastActivity: String? = nil) -> CodingSession {
        var json: [String: Any] = ["id": id, "status": status, "attached": attached]
        if let activity { json["activity_state"] = activity }
        if let cwd { json["cwd"] = cwd }
        if let source { json["source"] = source }
        if let lastActivity { json["last_activity_at"] = lastActivity }
        return CodingSession(json: json)
    }

    // MARK: - Fleet encoding

    func testEmptyViewProducesAnEmptyFleet() {
        let fleet = LiveFleet.from(CodingProjectsView(projects: [], ungrouped: []))
        XCTAssertEqual(fleet, .empty)
    }

    func testAProjectBecomesOneRowLabelledByTheProjectName() {
        let project = CodingProject(id: "p1", name: "hermes",
                                    sessions: [session("a", activity: "working")])
        let fleet = LiveFleet.from(CodingProjectsView(projects: [project], ungrouped: []))
        XCTAssertEqual(fleet.sessions, ["hermes\u{1f}working"])
        XCTAssertEqual(fleet.sessionTotal, 1)
        XCTAssertEqual(fleet.entryTotal, 1)
        XCTAssertEqual(fleet.waitingCount, 0)
    }

    func testASingleSessionRowCarriesNoSubStates() {
        let project = CodingProject(id: "p1", name: "solo",
                                    sessions: [session("a", activity: "waiting")])
        let fleet = LiveFleet.from(CodingProjectsView(projects: [project], ungrouped: []))
        XCTAssertEqual(fleet.sessions, ["solo\u{1f}waiting"],
                       "a one-session project renders as a single solid segment")
        XCTAssertEqual(fleet.waitingCount, 1)
    }

    func testAMultiSessionProjectAggregatesAndCarriesSubStates() {
        let project = CodingProject(id: "p1", name: "hermes", sessions: [
            session("a", activity: "working"),
            session("b", activity: "waiting"),
            session("c", activity: "idle"),
        ])
        let fleet = LiveFleet.from(CodingProjectsView(projects: [project], ungrouped: []))
        XCTAssertEqual(fleet.sessions, ["hermes\u{1f}waiting\u{1f}p,w,i"],
                       "waiting wins the aggregate and sorts first in the split bar")
        XCTAssertEqual(fleet.sessionTotal, 3)
        XCTAssertEqual(fleet.entryTotal, 1)
        XCTAssertEqual(fleet.waitingCount, 1)
    }

    func testUngroupedSessionsAreLabelledByTheirFolder() {
        let view = CodingProjectsView(projects: [], ungrouped: [
            session("a", activity: "working", cwd: "/Users/me/code/thing/"),
            session("b", activity: "working"),
        ])
        let fleet = LiveFleet.from(view)
        XCTAssertEqual(fleet.sessions.first, "thing\u{1f}working")
        XCTAssertTrue(fleet.sessions.contains("session\u{1f}working"),
                      "a session with no cwd still gets a label")
        XCTAssertEqual(fleet.entryTotal, 2)
    }

    func testTranscriptIdleAndDeadSessionsAreExcluded() {
        let view = CodingProjectsView(projects: [], ungrouped: [
            session("a", status: "stopped", source: "discovered-transcript"),
            session("b", status: "stopped"),
        ])
        XCTAssertEqual(LiveFleet.from(view), .empty)
    }

    func testForgottenDetachedSessionsAreDimmedAndSortLast() {
        let view = CodingProjectsView(projects: [], ungrouped: [
            session("dim", status: "idle", activity: "idle",
                    cwd: "/a/forgotten", source: "discovered-tmux", attached: false),
            session("hot", activity: "waiting", cwd: "/a/hot"),
        ])
        let fleet = LiveFleet.from(view)
        XCTAssertEqual(fleet.sessions, ["hot\u{1f}waiting", "forgotten\u{1f}dim"])
    }

    func testOnlyFourRowsAreSpotlightedButEntryTotalCountsThemAll() {
        let sessions = (0..<7).map { session("s\($0)", activity: "working", cwd: "/x/p\($0)") }
        let fleet = LiveFleet.from(CodingProjectsView(projects: [], ungrouped: sessions))
        XCTAssertEqual(fleet.sessions.count, 4)
        XCTAssertEqual(fleet.entryTotal, 7, "the widget renders '+3 more' from this")
        XCTAssertEqual(fleet.sessionTotal, 7)
    }

    func testLongLabelsAreTruncatedAndSeparatorsStripped() {
        let name = String(repeating: "x", count: 40) + "\u{1f}"
        let project = CodingProject(id: "p", name: name,
                                    sessions: [session("a", activity: "working")])
        let fleet = LiveFleet.from(CodingProjectsView(projects: [project], ungrouped: []))
        let label = fleet.sessions[0].components(separatedBy: "\u{1f}")[0]
        XCTAssertEqual(label.count, LiveFleet.labelLimit)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertEqual(fleet.sessions[0].components(separatedBy: "\u{1f}").count, 2,
                       "a name containing the separator must not fake a third field")
    }

    // MARK: - State

    func testAnIdleVoiceOnlyStateIsNotWorthStartingAnActivityFor() {
        XCTAssertFalse(LiveActivityState().isWorthStarting)
        XCTAssertTrue(LiveActivityState(state: "listening").isWorthStarting)
        XCTAssertTrue(LiveActivityState(mode: "coding", sessionTotal: 2).isWorthStarting)
        XCTAssertFalse(LiveActivityState(mode: "coding", sessionTotal: 0).isWorthStarting)
        XCTAssertTrue(LiveActivityState(mode: "custom", designId: "flight").isWorthStarting)
        XCTAssertFalse(LiveActivityState(mode: "custom", designId: "").isWorthStarting)
    }

    // MARK: - Coordinator

    private func makeCoordinator(controller: FakeActivityController,
                                 cache: RecordingIslandCache = RecordingIslandCache(),
                                 preferences: KeyValueStore = MemoryKeyValueStore(),
                                 paired: Bool = true,
                                 notifier: MockNotifier = MockNotifier())
    -> (LiveActivityCoordinator, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        let coordinator = LiveActivityCoordinator(
            coding: CodingSessionsAPI(api: api),
            islandAPI: IslandDesignsAPI(api: api),
            islandCache: cache,
            controller: controller,
            plan: IslandPlanNotifier(notifier: notifier),
            lifecycle: AppLifecycle(),
            preferences: preferences,
            isPaired: { paired },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            sleeper: instantSleeper)
        return (coordinator, transport)
    }

    func testAVoiceTurnPushesTheVoiceMode() {
        let controller = FakeActivityController()
        let (coordinator, _) = makeCoordinator(controller: controller)
        coordinator.reportVoice(VoiceLiveActivitySnapshot(
            state: "listening", transcript: "what's the weather", activity: "",
            connected: true, devices: ["phone", "laptop"]))

        XCTAssertEqual(controller.updates.count, 1)
        let state = controller.updates[0]
        XCTAssertEqual(state.mode, "voice")
        XCTAssertEqual(state.state, "listening")
        XCTAssertEqual(state.transcript, "what's the weather")
        XCTAssertEqual(state.devices, ["phone", "laptop"])
        XCTAssertTrue(state.isWorthStarting)
    }

    func testIdenticalSnapshotsAreNotPushedTwice() {
        let controller = FakeActivityController()
        let (coordinator, _) = makeCoordinator(controller: controller)
        let snapshot = VoiceLiveActivitySnapshot(
            state: "thinking", transcript: "hi", activity: "", connected: true, devices: [])
        coordinator.reportVoice(snapshot)
        coordinator.reportVoice(snapshot)
        XCTAssertEqual(controller.updates.count, 1,
                       "iOS budgets activity updates — churning them stuck the island")
    }

    func testLiveCodingSessionsFlipTheModeWhenVoiceIsIdle() async {
        let controller = FakeActivityController()
        let (coordinator, transport) = makeCoordinator(controller: controller)
        transport.route("/api/coding/projects", json: [
            "projects": [["id": "p1", "name": "hermes",
                          "sessions": [["id": "a", "status": "running",
                                        "activity_state": "waiting"]]]],
            "ungrouped": [],
        ])
        transport.route("/api/coding/usage", json: ["usage": ["five_hour_pct": 42,
                                                              "weekly_pct": 7,
                                                              "five_hour_resets": "2h 10m",
                                                              "weekly_resets": "Mon"]])
        // A real server always ships the built-in voice/coding catalog entries;
        // without a coding entry the auto picker has nothing to select.
        transport.route("/api/island/designs", json: [
            "designs": [],
            "catalog": [["id": "coding", "name": "Coding", "builtin": true,
                         "enabled": true, "priority": 10]],
        ])

        await coordinator.refreshCoding()

        guard let state = controller.updates.last else { return XCTFail("nothing pushed") }
        XCTAssertEqual(state.mode, "coding")
        XCTAssertEqual(state.sessions, ["hermes\u{1f}waiting"])
        XCTAssertEqual(state.sessionTotal, 1)
        XCTAssertEqual(state.waitingCount, 1)
        XCTAssertEqual(state.usage5, 42)
        XCTAssertEqual(state.usageWeek, 7)
        XCTAssertEqual(state.usage5Resets, "2h 10m")
    }

    func testAnActiveVoiceTurnBeatsLiveCodingSessions() async {
        let controller = FakeActivityController()
        let (coordinator, transport) = makeCoordinator(controller: controller)
        transport.route("/api/coding/projects", json: [
            "projects": [["id": "p1", "name": "hermes",
                          "sessions": [["id": "a", "status": "running",
                                        "activity_state": "working"]]]],
            "ungrouped": [],
        ])
        transport.route("/api/coding/usage", json: ["usage": [:]])
        transport.route("/api/island/designs", json: [
            "designs": [],
            "catalog": [["id": "coding", "name": "Coding", "builtin": true,
                         "enabled": true, "priority": 10]],
        ])
        await coordinator.refreshCoding()
        XCTAssertEqual(controller.updates.last?.mode, "coding")

        coordinator.reportVoice(VoiceLiveActivitySnapshot(
            state: "speaking", transcript: "", activity: "", connected: true, devices: []))

        XCTAssertEqual(controller.updates.last?.mode, "voice")
        XCTAssertEqual(controller.updates.last?.sessions, [],
                       "the coding fields are cleared so the widget can't render both")
    }

    func testTurningTheSettingOffEndsTheActivityAndStopsPushing() {
        let controller = FakeActivityController()
        let (coordinator, _) = makeCoordinator(controller: controller)
        coordinator.reportVoice(VoiceLiveActivitySnapshot(
            state: "listening", transcript: "", activity: "", connected: true, devices: []))
        XCTAssertEqual(controller.updates.count, 1)

        coordinator.setEnabled(false)
        XCTAssertEqual(controller.ends, 1)

        coordinator.reportVoice(VoiceLiveActivitySnapshot(
            state: "speaking", transcript: "x", activity: "", connected: true, devices: []))
        XCTAssertEqual(controller.updates.count, 1,
                       "a stale island after the user switched the feature off is never acceptable")
    }

    func testStartRespectsTheStoredToggle() {
        let controller = FakeActivityController()
        let preferences = MemoryKeyValueStore([SettingsStore.Keys.liveActivities: false])
        let (coordinator, _) = makeCoordinator(controller: controller, preferences: preferences)
        coordinator.start()
        XCTAssertFalse(coordinator.enabled)
        coordinator.reportVoice(VoiceLiveActivitySnapshot(
            state: "listening", transcript: "", activity: "", connected: true, devices: []))
        XCTAssertTrue(controller.updates.isEmpty)
    }

    func testTheDefaultIsOnBecauseCredentialsDartReadItAsNotZero() {
        let controller = FakeActivityController()
        let (coordinator, _) = makeCoordinator(controller: controller)
        coordinator.start()
        XCTAssertTrue(coordinator.enabled)
    }

    func testAnUnpairedDeviceNeverFetches() async {
        let controller = FakeActivityController()
        let (coordinator, transport) = makeCoordinator(controller: controller, paired: false)
        await coordinator.refreshCoding()
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testABackgroundTickIsThrottledToTheSlowInterval() async {
        let controller = FakeActivityController()
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/projects", json: ["projects": [], "ungrouped": []])
        transport.route("/api/coding/usage", json: ["usage": [:]])
        transport.route("/api/island/designs", json: ["designs": [], "catalog": []])
        let lifecycle = AppLifecycle()
        lifecycle.isForeground = false
        let coordinator = LiveActivityCoordinator(
            coding: CodingSessionsAPI(api: api), islandAPI: IslandDesignsAPI(api: api),
            islandCache: RecordingIslandCache(), controller: controller,
            plan: IslandPlanNotifier(notifier: MockNotifier()),
            lifecycle: lifecycle, preferences: MemoryKeyValueStore(),
            isPaired: { true }, now: { Date(timeIntervalSince1970: 1_700_000_000) },
            sleeper: instantSleeper)

        await coordinator.tick()
        let afterFirst = transport.requests.count
        await coordinator.tick()

        XCTAssertGreaterThan(afterFirst, 0, "a backgrounded but living app still refreshes")
        XCTAssertEqual(transport.requests.count, afterFirst,
                       "the second tick is inside the 30 s background window")
    }

    func testActivityPushTokensAreRegisteredOnceEach() async {
        let controller = FakeActivityController()
        // Bind the coordinator: it owns the token callback, and letting it
        // deallocate would silently swallow every token.
        let (coordinator, transport) = makeCoordinator(controller: controller)
        transport.route("/api/coding/la-token", json: ["ok": true])

        controller.emitToken("abc123")
        controller.emitToken("abc123")
        await servicesWaitUntil { transport.requests.count >= 1 }

        XCTAssertEqual(transport.requests.count, 1, "tokens rotate; only changes are registered")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/coding/la-token")
        XCTAssertEqual(transport.lastBody()["token"] as? String, "abc123")
        XCTAssertTrue(coordinator.enabled)
    }

    func testDesignsAreCachedForTheWidgetToRead() async {
        let controller = FakeActivityController()
        let cache = RecordingIslandCache()
        let (coordinator, transport) = makeCoordinator(controller: controller, cache: cache)
        transport.route("/api/coding/projects", json: ["projects": [], "ungrouped": []])
        transport.route("/api/coding/usage", json: ["usage": [:]])
        transport.route("/api/island/designs", json: [
            "designs": [["id": "flight", "version": 2, "root": ["type": "text"]]],
            "catalog": [],
        ])

        await coordinator.refreshCoding()
        await servicesWaitUntil { !cache.cached.isEmpty }

        XCTAssertTrue(cache.cached.contains { $0["id"] as? String == "flight" },
                      "the tree is too big for the 4 KB ContentState — it goes to the App Group")
    }

    // MARK: - setCodingVisible (cadence)

    /// The Coding tab's visibility hook. It only matters through
    /// `LivePollPolicy`, which is what turns "the user is watching" into the
    /// fast cadence before any session has gone live.
    func testSetCodingVisibleDrivesTheFastCadence() {
        let (coordinator, _) = makeCoordinator(controller: FakeActivityController())
        XCTAssertFalse(coordinator.codingVisible, "the app does not start on the Coding tab")

        coordinator.setCodingVisible(true)
        XCTAssertTrue(coordinator.codingVisible)

        coordinator.setCodingVisible(false)
        XCTAssertFalse(coordinator.codingVisible)

        let watching = LivePollPolicy.pollInterval(voiceActive: false, codingVisible: true,
                                                   sessionTotal: 0)
        let away = LivePollPolicy.pollInterval(voiceActive: false, codingVisible: false,
                                               sessionTotal: 0)
        XCTAssertLessThan(watching, away,
                          "watching the tab has to poll faster than not watching it")
    }

    // MARK: - ActivityUpdateQueue (swift-correctness M22)

    /// ActivityKit updates must land in the order they were produced. An
    /// unstructured `Task` per update lets a slow early frame overwrite a newer
    /// one and freeze the island on stale text.
    func testTheUpdateQueueRunsWorkInSubmissionOrder() async {
        let queue = ActivityUpdateQueue()
        let order = OrderRecorder()

        queue.enqueue { try? await Task.sleep(nanoseconds: 30_000_000); await order.append(1) }
        queue.enqueue { try? await Task.sleep(nanoseconds: 10_000_000); await order.append(2) }
        queue.enqueue { await order.append(3) }
        await queue.drain()

        let values = await order.values
        XCTAssertEqual(values, [1, 2, 3],
                       "a slow first update must not be overtaken by the ones after it")
    }

    func testDrainingAnEmptyQueueIsANoOp() async {
        await ActivityUpdateQueue().drain()
    }
}

/// Records completion order across the queue's tasks.
actor OrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
