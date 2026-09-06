import XCTest
@testable import JarvisCopilot

/// The dispatch rules the Flutter `InvokeRunner` enforced: pause, the
/// `skills_disabled` ACL, unknown skills, and the foreground-defer path from
/// `test/services/foreground_defer_test.dart`.
@MainActor
final class InvokeRunnerTests: XCTestCase {

    private struct Harness {
        let runner: InvokeRunner
        let registry: SkillRegistry
        let lifecycle: AppLifecycle
        let pending: PendingActions
        let notifier: MockNotifier
        let store: MemoryKeyValueStore
        let ran: Counter
    }

    /// A box the skill closure can bump without capturing a `var`.
    private final class Counter {
        var calls: [[String: Any]] = []
    }

    private func harness(name: String = "demo",
                         foreground: Bool = true,
                         result: [String: Any] = ["ok": true],
                         requiresForeground: Bool = false,
                         error: Error? = nil,
                         notifierError: Error? = nil,
                         store: MemoryKeyValueStore = MemoryKeyValueStore()) -> Harness {
        let counter = Counter()
        let skill = AnySkill(name: name, description: "demo skill",
                             requiresForeground: requiresForeground) { args in
            counter.calls.append(args)
            if let error { throw error }
            return result
        }
        let registry = SkillRegistry(store: MemoryKeyValueStore(), skills: [skill])
        let lifecycle = AppLifecycle()
        lifecycle.isForeground = foreground
        let pending = PendingActions()
        let notifier = MockNotifier()
        notifier.error = notifierError
        let runner = InvokeRunner(registry: registry, lifecycle: lifecycle,
                                  pending: pending, notifier: notifier, store: store)
        return Harness(runner: runner, registry: registry, lifecycle: lifecycle,
                       pending: pending, notifier: notifier, store: store, ran: counter)
    }

    // MARK: happy path

    func testRunsTheSkillAndLogsIt() async {
        let h = harness()
        let outcome = await h.runner.run("demo", ["x": 1])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?["ok"] as? Bool, true)
        XCTAssertEqual(h.ran.calls.count, 1)
        XCTAssertEqual(h.ran.calls.first?["x"] as? Int, 1)
        XCTAssertEqual(h.runner.log.first?.skill, "demo")
        XCTAssertNil(h.runner.log.first?.error)
    }

    func testAThrownSkillErrorBecomesAReadableMessage() async {
        let h = harness(error: SkillError.badArgument("url required"))
        let outcome = await h.runner.run("demo", [:])
        XCTAssertEqual(outcome.error, "url required")
        XCTAssertNil(outcome.result)
        XCTAssertEqual(h.runner.log.first?.error, "url required")
    }

    func testPermissionDeniedReadsAsASentence() async {
        let h = harness(error: SkillError.permissionDenied("contacts"))
        let outcome = await h.runner.run("demo", [:])
        XCTAssertEqual(outcome.error, "contacts permission denied")
    }

    // MARK: gates

    func testPausedRefusesWithoutTouchingTheSkill() async {
        let h = harness()
        h.runner.paused = true
        let outcome = await h.runner.run("demo", [:])
        XCTAssertEqual(outcome.error, "paused")
        XCTAssertTrue(h.ran.calls.isEmpty)
    }

    /// The pause toggle is a kill switch; losing it on relaunch silently
    /// re-armed every skill for a user who had deliberately switched it off.
    func testThePauseKillSwitchSurvivesARelaunch() async {
        let store = MemoryKeyValueStore()
        let first = harness(store: store)
        first.runner.paused = true
        XCTAssertEqual(store.bool(InvokeRunner.pausedKey), true)

        let relaunched = harness(store: store)
        XCTAssertTrue(relaunched.runner.paused)
        let outcome = await relaunched.runner.run("demo", [:])
        XCTAssertEqual(outcome.error, "paused")

        relaunched.runner.paused = false
        XCTAssertEqual(store.bool(InvokeRunner.pausedKey), false)
        XCTAssertFalse(harness(store: store).runner.paused)
    }

    func testADisabledSkillIsRefused() async {
        let h = harness()
        h.registry.setEnabled(false, for: "demo")
        let outcome = await h.runner.run("demo", [:])
        XCTAssertEqual(outcome.error, "skill disabled by user")
        XCTAssertTrue(h.ran.calls.isEmpty)
    }

    func testAnUnknownSkillIsRefused() async {
        let h = harness()
        let outcome = await h.runner.run("nope", [:])
        XCTAssertEqual(outcome.error, "unknown skill: nope")
    }

    // MARK: foreground defer

    func testAForegroundRequiredSkillIsDeferredWhileBackgrounded() async throws {
        // `open_app` so the banner goes through the real per-skill title.
        let h = harness(name: "open_app", foreground: false, requiresForeground: true)
        let outcome = await h.runner.run("open_app", ["app": "Robinhood"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?["queued"] as? Bool, true)
        XCTAssertTrue(h.ran.calls.isEmpty, "the skill must not run while backgrounded")
        XCTAssertEqual(h.pending.count, 1)

        // The banner + its replay payload are posted as a local notification,
        // awaited inside `run` — the deferral is not real until it lands.
        let posted = try XCTUnwrap(h.notifier.posted.first)
        XCTAssertEqual(posted.title, "Open Robinhood")
        XCTAssertEqual(posted.body, "Tap to run")
        let payload = try XCTUnwrap(posted.payload)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["__jcIslandAction"] as? Bool, true)
        XCTAssertEqual((decoded["action"] as? [String: Any])?["skill"] as? String, "open_app")
    }

    /// The notification IS the deferral: with notifications off there is
    /// nothing to tap, so answering `queued: true` told the agent the action was
    /// on its way when it had silently vanished.
    func testADeferralFailsLoudlyWhenTheNotificationCannotBePosted() async {
        let h = harness(name: "open_app", foreground: false, requiresForeground: true,
                        notifierError: SkillError.permissionDenied("notifications"))
        let outcome = await h.runner.run("open_app", ["app": "Robinhood"])
        XCTAssertEqual(outcome.error, "notifications are off — enable them to run this")
        XCTAssertNil(outcome.result)
        XCTAssertTrue(h.pending.isEmpty, "nothing may be queued that can't be surfaced")
        XCTAssertEqual(h.runner.log.first?.error, "notifications permission denied")
    }

    func testAForegroundRequiredSkillRunsNormallyInTheForeground() async {
        let h = harness(foreground: true, requiresForeground: true)
        _ = await h.runner.run("demo", [:])
        XCTAssertEqual(h.ran.calls.count, 1)
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testANonForegroundSkillIsNeverDeferred() async {
        let h = harness(foreground: false, requiresForeground: false)
        _ = await h.runner.run("demo", [:])
        XCTAssertEqual(h.ran.calls.count, 1)
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testDrainPendingRunsDeferredActionsOnResume() async {
        let h = harness(foreground: false, requiresForeground: true)
        _ = await h.runner.run("demo", ["app": "X"])
        XCTAssertEqual(h.ran.calls.count, 0)

        // Nothing drains while still backgrounded.
        let whileBackgrounded = await h.runner.drainPending()
        XCTAssertEqual(whileBackgrounded, 0)
        XCTAssertEqual(h.pending.count, 1)

        h.lifecycle.isForeground = true
        let drained = await h.runner.drainPending()
        XCTAssertEqual(drained, 1)
        XCTAssertEqual(h.ran.calls.count, 1)
        XCTAssertEqual(h.ran.calls.first?["app"] as? String, "X")
        XCTAssertTrue(h.pending.isEmpty)
    }

    func testAStaleDeferredActionIsDroppedRatherThanFiredLate() async {
        let h = harness(foreground: true, requiresForeground: true)
        h.pending.add("demo", ["app": "stale"], at: Date(timeIntervalSince1970: 0))
        let drained = await h.runner.drainPending()
        XCTAssertEqual(drained, 0)
        XCTAssertTrue(h.ran.calls.isEmpty)
    }

    // MARK: localToolMissed

    func testLocalToolMissedOnlyFlagsAnOpenAppThatDidNotLaunch() {
        XCTAssertTrue(localToolMissed("open_app", .ok(["launched": false])))
        XCTAssertFalse(localToolMissed("open_app", .ok(["launched": true])))
        // A thrown error is surfaced normally, not treated as a "miss".
        XCTAssertFalse(localToolMissed("open_app", .err("boom")))
        // Other skills never "miss".
        XCTAssertFalse(localToolMissed("notify", .ok(["launched": false])))
    }

    // MARK: log

    func testTheLogIsNewestFirstAndBounded() async {
        let h = harness()
        for i in 0..<210 { _ = await h.runner.run("demo", ["i": i]) }
        XCTAssertEqual(h.runner.log.count, 200)
        XCTAssertEqual(h.runner.log.first?.args["i"] as? Int, 209)
    }
}
