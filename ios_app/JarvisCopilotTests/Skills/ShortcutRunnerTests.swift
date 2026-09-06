import XCTest
@testable import JarvisCopilot

/// The `shortcuts://x-callback-url` plumbing and the app-scheme table.
@MainActor
final class ShortcutRunnerTests: XCTestCase {

    // MARK: URL building

    func testLaunchModeOmitsTheCallbacksAndReturnsImmediately() async throws {
        let urls = MockURLOpener()
        let runner = DefaultShortcutRunner(urls: urls)
        let outcome = await runner.run(name: "JC Open App", input: "Chase",
                                       timeoutSeconds: 90, awaitResult: false)
        XCTAssertTrue(outcome.ran)
        XCTAssertTrue(outcome.launched)
        let url = try XCTUnwrap(urls.opened.first?.absoluteString)
        XCTAssertTrue(url.hasPrefix("shortcuts://x-callback-url/run-shortcut?"))
        // Spaces must be %20, never `+` — Shortcuts treats `+` as a literal.
        XCTAssertTrue(url.contains("name=JC%20Open%20App"), url)
        XCTAssertFalse(url.contains("+"), url)
        XCTAssertTrue(url.contains("input=text"), url)
        XCTAssertTrue(url.contains("text=Chase"), url)
        XCTAssertFalse(url.contains("x-success"), url)
    }

    func testAwaitModeIncludesTheCallbacks() async throws {
        let urls = MockURLOpener()
        let runner = DefaultShortcutRunner(urls: urls)
        // Nothing will deliver a result, so it falls through to the timeout note
        // — the same shape the Flutter client produced. 1 s keeps it quick.
        let outcome = await runner.run(name: "JC WiFi", input: "0",
                                       timeoutSeconds: 1, awaitResult: true)
        XCTAssertTrue(outcome.ran)
        XCTAssertNotNil(outcome.note)
        let url = try XCTUnwrap(urls.opened.first?.absoluteString)
        XCTAssertTrue(url.contains("x-success=jarviscopilot%3A%2F%2Fshortcut-result%2Fsc"), url)
        XCTAssertTrue(url.contains("x-error="), url)
        XCTAssertTrue(url.contains("x-cancel="), url)
    }

    func testAFailedLaunchIsReportedNotAwaited() async {
        let runner = DefaultShortcutRunner(urls: MockURLOpener(openResult: false))
        let outcome = await runner.run(name: "JC WiFi", input: "0",
                                       timeoutSeconds: 30, awaitResult: true)
        XCTAssertFalse(outcome.ran)
        XCTAssertEqual(outcome.error, "Could not open Shortcuts (is it installed?)")
    }

    func testOpenEditorOpensCreateOrImport() async throws {
        let urls = MockURLOpener()
        let runner = DefaultShortcutRunner(urls: urls)

        let createOpened = await runner.openEditor(importURL: "", suggestedName: "")
        XCTAssertTrue(createOpened)
        XCTAssertEqual(urls.opened.last?.absoluteString, "shortcuts://create-shortcut")

        let importOpened = await runner.openEditor(importURL: "https://x.com/a.shortcut",
                                                   suggestedName: "JC X")
        XCTAssertTrue(importOpened)
        let url = try XCTUnwrap(urls.opened.last?.absoluteString)
        XCTAssertTrue(url.hasPrefix("shortcuts://x-callback-url/import-shortcut?"), url)
        XCTAssertTrue(url.contains("name=JC%20X"), url)
    }

    // MARK: result callback parsing

    func testParsesASuccessCallback() throws {
        let url = try XCTUnwrap(URL(string: "jarviscopilot://shortcut-result/sc123?result=73%25"))
        let parsed = try XCTUnwrap(ShortcutResultBus.parse(url))
        XCTAssertEqual(parsed.rid, "sc123")
        XCTAssertTrue(parsed.outcome.ran)
        XCTAssertEqual(parsed.outcome.result, "73%")
    }

    func testParsesAnEmptySuccessCallback() throws {
        let url = try XCTUnwrap(URL(string: "jarviscopilot://shortcut-result/sc123"))
        let parsed = try XCTUnwrap(ShortcutResultBus.parse(url))
        XCTAssertTrue(parsed.outcome.ran)
        XCTAssertEqual(parsed.outcome.result, "")
    }

    func testParsesAnErrorCallback() throws {
        let url = try XCTUnwrap(
            URL(string: "jarviscopilot://shortcut-error/sc9?errorMessage=nope"))
        let parsed = try XCTUnwrap(ShortcutResultBus.parse(url))
        XCTAssertEqual(parsed.rid, "sc9")
        XCTAssertFalse(parsed.outcome.ran)
        XCTAssertEqual(parsed.outcome.error, "nope")
    }

    func testIgnoresForeignURLs() {
        for text in ["https://example.com/shortcut-result/sc1",
                     "jarviscopilot://something-else/sc1",
                     "jarviscopilot://shortcut-result/"] {
            XCTAssertNil(ShortcutResultBus.parse(URL(string: text)!), text)
        }
    }

    func testDeliverCompletesAWaitingRun() async {
        let bus = ShortcutResultBus()
        bus.arm("scX")
        let waiting = Task { await bus.wait("scX", timeoutSeconds: 5) }
        // Poll for the registered continuation rather than sleeping a guess.
        await skillsWaitUntil { bus.isWaiting("scX") }
        XCTAssertTrue(bus.isWaiting("scX"))
        XCTAssertTrue(bus.deliver(URL(string: "jarviscopilot://shortcut-result/scX?result=ok")!))
        let outcome = await waiting.value
        XCTAssertEqual(outcome?.result, "ok")
        XCTAssertFalse(bus.isWaiting("scX"))
    }

    /// The timeout used to be armed BEFORE the continuation was installed, so a
    /// timeout that fired in the gap found no waiter and the continuation that
    /// landed afterwards was never resumed — the call hung forever. A 1 s
    /// timeout must still come back, and come back exactly once.
    func testAWaitAlwaysCompletesEvenWithTheShortestTimeout() async {
        let bus = ShortcutResultBus()
        bus.arm("scT")
        let waiting = Task { await bus.wait("scT", timeoutSeconds: 1) }
        await skillsWaitUntil { bus.isWaiting("scT") }
        let outcome = await waiting.value
        XCTAssertNil(outcome)
        XCTAssertFalse(bus.isWaiting("scT"), "the waiter must be gone, not double-resumed")
        // A late callback for a run nobody is waiting on is parked, not crashed.
        XCTAssertTrue(bus.deliver(URL(string: "jarviscopilot://shortcut-result/scT?result=late")!))
    }

    // MARK: early results are bounded

    /// `early` is fed by INCOMING URLs — anything that can open the app can grow
    /// it — and nothing pruned it.
    func testUnclaimedEarlyResultsAreCappedAndExpired() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let bus = ShortcutResultBus(clock: { now })
        for i in 0..<(ShortcutResultBus.earlyCap + 20) {
            bus.deliver(URL(string: "jarviscopilot://shortcut-result/sc\(i)?result=\(i)")!)
            now = now.addingTimeInterval(1)
        }
        XCTAssertEqual(bus.earlyCount, ShortcutResultBus.earlyCap)
        // The newest survive; the oldest were dropped.
        let newest = await bus.wait("sc\(ShortcutResultBus.earlyCap + 19)", timeoutSeconds: 1)
        XCTAssertEqual(newest?.result, "\(ShortcutResultBus.earlyCap + 19)")

        // Past the TTL everything left is dropped rather than delivered late.
        now = now.addingTimeInterval(ShortcutResultBus.earlyTTL + 1)
        bus.deliver(URL(string: "jarviscopilot://shortcut-result/fresh?result=ok")!)
        XCTAssertEqual(bus.earlyCount, 1)
    }

    func testAResultThatArrivesBeforeTheWaitIsStillDelivered() async {
        let bus = ShortcutResultBus()
        bus.arm("scY")
        XCTAssertTrue(bus.deliver(URL(string: "jarviscopilot://shortcut-result/scY?result=fast")!))
        let outcome = await bus.wait("scY", timeoutSeconds: 5)
        XCTAssertEqual(outcome?.result, "fast")
    }

    func testWaitTimesOut() async {
        let bus = ShortcutResultBus()
        bus.arm("scZ")
        let timedOut = await bus.wait("scZ", timeoutSeconds: 1)
        XCTAssertNil(timedOut)
    }

    // MARK: app scheme table

    func testAnExplicitSchemeWins() {
        XCTAssertEqual(AppSchemeTable.resolve(appName: "spotify", schemeURL: "custom://x"),
                       "custom://x")
    }

    func testAFriendlyNameMapsToItsScheme() {
        XCTAssertEqual(AppSchemeTable.resolve(appName: "spotify", schemeURL: ""), "spotify://")
        XCTAssertEqual(AppSchemeTable.resolve(appName: "google maps", schemeURL: ""),
                       "comgooglemaps://")
        XCTAssertEqual(AppSchemeTable.resolve(appName: "googlemaps", schemeURL: ""),
                       "comgooglemaps://")
        XCTAssertEqual(AppSchemeTable.resolve(appName: "x", schemeURL: ""), "twitter://")
    }

    func testAnUnknownNameFallsBackToItsCondensedForm() {
        XCTAssertEqual(AppSchemeTable.resolve(appName: "wells fargo", schemeURL: ""),
                       "wellsfargo://")
    }

    func testNothingToTryReturnsNil() {
        XCTAssertNil(AppSchemeTable.resolve(appName: "  ", schemeURL: "  "))
        XCTAssertNil(AppSchemeTable.resolve(appName: "!!!", schemeURL: ""))
    }

    func testDefaultAppOpenerReportsWhatActuallyHappened() async {
        let urls = MockURLOpener(openResult: false)
        let opener = DefaultAppOpener(urls: urls)
        let outcome = await opener.open(appName: "spotify", schemeURL: "")
        XCTAssertFalse(outcome.launched)
        XCTAssertEqual(outcome.schemeURL, "spotify://")
        XCTAssertEqual(urls.opened.first?.absoluteString, "spotify://")
    }

    func testDefaultAppOpenerReportsNoSchemeAtAll() async {
        let outcome = await DefaultAppOpener(urls: MockURLOpener()).open(appName: "", schemeURL: "")
        XCTAssertFalse(outcome.launched)
        XCTAssertEqual(outcome.error, "no scheme for \"\"")
    }
}
