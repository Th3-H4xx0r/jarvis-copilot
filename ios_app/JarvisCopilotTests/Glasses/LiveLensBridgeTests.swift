import XCTest
@testable import JarvisCopilot

@MainActor
final class LiveLensBridgeTests: XCTestCase {
    final class FakeSource: LiveCaptionSource {
        var isCapturing = true
        var snapshot = LiveCaptionSnapshot(partial: "", segments: [])
        var startCalls = 0
        func captionSnapshot() -> LiveCaptionSnapshot { snapshot }
        var startSucceeds = true
        func startCapture() async -> Bool { startCalls += 1; isCapturing = startSucceeds; return startSucceeds }
    }
    final class FakeSurface: LensCaptionSurface {
        let module: Int
        var calls: [String] = []
        init(module: Int) { self.module = module }
        func open() { calls.append("open") }
        func show(_ caption: LensCaption) { calls.append((caption.final ? "final " : "partial ") + caption.text) }
        func close() { calls.append("close") }
    }

    private var source = FakeSource()
    private var surface = FakeSurface(module: 8)
    private var busy = false
    private var ready = true
    private var clock = Date(timeIntervalSince1970: 1000)
    private let suite = "LiveLensBridgeTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    override func setUp() {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        source = FakeSource(); surface = FakeSurface(module: 8); busy = false; ready = true
    }
    private func bridge() -> LiveLensBridge {
        LiveLensBridge(source: { [unowned self] in source }, defaults: defaults, lensBusy: { [unowned self] in busy },
                       glassesReady: { [unowned self] in ready },
                       surface: { [unowned self] style in style == .subtitles ? surface : FakeSurface(module: 0) },
                       now: { [unowned self] in clock })
    }
    private func seg(_ seq: Int, _ name: String, _ text: String) -> LiveCaptionSegment {
        .init(seq: seq, name: name, text: text, translation: "")
    }

    func testOffByDefaultAndShowsOnlyWhenEnabledRecordingAndReady() {
        let b = bridge()
        XCTAssertFalse(b.enabled)
        b.refresh()
        XCTAssertEqual(surface.calls, [])
        b.enabled = true
        XCTAssertEqual(surface.calls, ["open"])
        XCTAssertEqual(b.status, .showing)
        source.snapshot = .init(partial: "", segments: [seg(1, "Maya", "hi")])
        b.refresh()
        XCTAssertEqual(surface.calls, ["open", "final Maya — hi"])
        source.isCapturing = false
        b.refresh()
        XCTAssertEqual(surface.calls.last, "close")
        XCTAssertEqual(b.status, .notRecording)
    }

    func testTheToggleIsRemembered() {
        bridge().enabled = true
        XCTAssertTrue(bridge().enabled)
    }

    func testOwnEchoesAreIgnoredAndAGlassesCloseTurnsItOff() {
        let b = bridge()
        b.enabled = true                              // opens app 8
        b.handleLens(module: 8, opened: true)          // echo of our open
        XCTAssertTrue(b.enabled)
        XCTAssertEqual(surface.calls.filter { $0 == "open" }.count, 1)
        b.handleLens(module: 8, opened: false)         // the user closed Subtitles on the glasses
        XCTAssertFalse(b.enabled)
        XCTAssertEqual(surface.calls.last, "open")     // nothing sent back
        b.handleLens(module: 8, opened: false)         // a later echo changes nothing
        XCTAssertFalse(b.enabled)
    }

    func testOpeningSubtitlesOnTheGlassesTurnsItOnAndStartsLive() async {
        source.isCapturing = false
        let b = bridge()
        b.handleLens(module: 8, opened: true)
        for _ in 0..<20 where b.status != .showing { await Task.yield() }
        XCTAssertTrue(b.enabled)
        XCTAssertEqual(source.startCalls, 1)
        XCTAssertEqual(b.status, .showing)
    }

    func testItStepsAsideForAnotherLensAppAndComesBack() {
        let b = bridge()
        b.enabled = true
        source.snapshot = .init(partial: "", segments: [seg(1, "Maya", "one")])
        b.refresh()
        b.handleLens(module: 5, opened: true)          // an AI note took the lens
        XCTAssertEqual(b.status, .pausedForLens)
        source.snapshot = .init(partial: "", segments: [seg(1, "Maya", "one"), seg(2, "Maya", "two")])
        b.refresh()
        XCTAssertFalse(surface.calls.contains("final Maya — two"))
        XCTAssertFalse(surface.calls.contains("close"))  // never closes the other app
        b.handleLens(module: 5, opened: false)
        XCTAssertEqual(b.status, .showing)
        XCTAssertEqual(Array(surface.calls.suffix(2)), ["open", "final Maya — two"])
    }

    func testANoteOrTranslationSessionAlsoTakesTheLens() {
        let b = bridge()
        b.enabled = true
        busy = true
        b.refresh()
        XCTAssertEqual(b.status, .pausedForLens)
        busy = false
        b.refresh()
        XCTAssertEqual(b.status, .showing)
    }

    func testGlassesOffStopsAndReconnectResumes() {
        let b = bridge()
        b.enabled = true
        ready = false
        b.refresh()
        XCTAssertEqual(b.status, .glassesOff)
        ready = true
        b.refresh()
        XCTAssertEqual(b.status, .showing)
        XCTAssertEqual(surface.calls.filter { $0 == "open" }.count, 2)
    }

    func testPartialWordsAreRateLimited() {
        let b = bridge()
        b.enabled = true
        source.snapshot = .init(partial: "are", segments: [])
        b.refresh()
        source.snapshot = .init(partial: "are we", segments: [])
        b.refresh()                                     // same instant: held
        XCTAssertEqual(surface.calls.filter { $0.hasPrefix("partial") }, ["partial are"])
        clock = clock.addingTimeInterval(0.31)
        b.refresh()                                     // later: the held words go
        XCTAssertEqual(surface.calls.filter { $0.hasPrefix("partial") }, ["partial are", "partial are we"])
    }

    func testTheBridgeReportsTheLensAppItOwns() {
        let b = bridge()
        b.style = .translation
        b.enabled = true
        XCTAssertTrue(b.ownsLens(module: 0))
        XCTAssertFalse(b.ownsLens(module: 8))
        b.enabled = false
        XCTAssertFalse(b.ownsLens(module: 0))
    }

    /// Answers and fact-checks framed as text on the lens, in readable chunks.
    func testABlockIsFramedAndChunked() {
        let short = LiveLensBridge.frame(title: "Jarvis", body: "Yes, that's a fair price.")
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short[0].hasPrefix("━━━ 【Jarvis】 ━━━\n"))
        XCTAssertTrue(short[0].hasSuffix("\n" + LiveLensBridge.blockBar))
        let long = LiveLensBridge.frame(title: "Fact-check", body: Array(repeating: "word", count: 80).joined(separator: " "))
        XCTAssertGreaterThan(long.count, 1)
        XCTAssertTrue(long[0].hasPrefix("━━━ 【Fact-check】 ━━━\n"))
        XCTAssertTrue(long.last!.hasSuffix(LiveLensBridge.blockBar))
        XCTAssertTrue(long.allSatisfy { $0.count <= LiveLensBridge.blockChunk + 60 })
    }

    func testLiveCaptionsWaitWhileABlockIsShowing() async {
        let b = bridge()
        b.enabled = true
        b.showBlock(title: "Jarvis", body: "short answer")
        for _ in 0..<10 where !surface.calls.contains(where: { $0.contains("【Jarvis】") }) { await Task.yield() }
        source.snapshot = .init(partial: "", segments: [seg(1, "Maya", "during")])
        b.refresh()
        XCTAssertFalse(surface.calls.contains("final Maya — during"))
    }

    /// Review C2: the test action's own open/close echoes are not the user.
    func testTheTestCaptionEchoesAreIgnored() {
        let b = bridge()
        b.beginProbe(module: 8)
        b.handleLens(module: 8, opened: true)
        XCTAssertFalse(b.enabled)
        XCTAssertEqual(source.startCalls, 0)
        XCTAssertTrue(b.ownsLens(module: 8))
        b.handleLens(module: 8, opened: false)
        b.endProbe()
        XCTAssertFalse(b.ownsLens(module: 8))
    }

    /// Review I3: a glasses-started open that cannot start Live leaves the toggle as it was.
    func testAFailedGlassesStartRestoresTheToggle() async {
        source.isCapturing = false
        source.startSucceeds = false
        let b = bridge()
        b.handleLens(module: 8, opened: true)
        for _ in 0..<20 where b.notice == nil { await Task.yield() }
        XCTAssertFalse(b.enabled)
        XCTAssertNotNil(b.notice)
    }

    /// Review I4: a lost connection forgets which other app had the lens.
    func testReconnectingForgetsAnotherAppThatNeverClosed() {
        let b = bridge()
        b.enabled = true
        b.handleLens(module: 5, opened: true)
        XCTAssertEqual(b.status, .pausedForLens)
        ready = false
        b.connectionChanged()
        ready = true
        b.connectionChanged()
        XCTAssertEqual(b.status, .showing)
    }
}