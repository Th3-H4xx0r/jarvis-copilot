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
        var factChecks = 0
        func runFactCheck() async -> (title: String, text: String)? { factChecks += 1; return ("Fact-check · TRUE", "Checked.") }
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
    private var posted: [Data] = []
    private let suite = "LiveLensBridgeTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    override func setUp() {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        source = FakeSource(); surface = FakeSurface(module: 8); busy = false; ready = true; posted = []
    }
    private func bridge() -> LiveLensBridge {
        LiveLensBridge(source: { [unowned self] in source }, defaults: defaults, lensBusy: { [unowned self] in busy },
                       glassesReady: { [unowned self] in ready },
                       surface: { [unowned self] style in style == .subtitles ? surface : FakeSurface(module: 0) },
                       now: { [unowned self] in clock },
                       post: { [unowned self] in posted.append($0) })
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

    /// Two questions in a row: each gets its own framed block, one after the other.
    func testEachBlockKeepsItsOwnHeaderAndTheyDoNotInterleave() async {
        let b = bridge()
        b.enabled = true
        b.chunkGap = .zero; b.blockGap = .zero
        b.showBlock(title: "Jarvis", parts: ["Q: one", "A: first"])
        b.showBlock(title: "Jarvis", parts: ["Q: two", "A: second"])
        for _ in 0..<100 where surface.calls.filter({ $0.contains("【Jarvis】") }).count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let blocks = surface.calls.filter { $0.contains("【Jarvis】") }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].contains("Q: one") && blocks[0].contains("A: first"))
        XCTAssertTrue(blocks[1].contains("Q: two") && blocks[1].contains("A: second"))
    }

    /// A gesture learned in the app runs a fact-check when the glasses send it again.
    func testALearnedGlassesGestureRunsAFactCheck() async {
        let b = bridge()
        b.enabled = true
        let gesture = Data([0x10, 0x07, 0x42, 0x02, 0x08, 0x01])
        b.learnGesture()
        b.handleGlasses(type: 7, fields: [], raw: gesture)
        XCTAssertFalse(b.learningGesture)
        XCTAssertNotNil(b.factCheckGesture)
        b.handleGlasses(type: 7, fields: [], raw: gesture)
        for _ in 0..<100 where source.factChecks == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(source.factChecks, 1)
        // Noise the glasses send on their own is never learned.
        b.learnGesture()
        b.handleGlasses(type: 20, fields: [], raw: Data([0x10, 0x14]))
        XCTAssertTrue(b.learningGesture)
    }

    /// Taps and swipes never reach the phone; leaving Subtitles on the glasses does.
    /// That exit can be the gesture: it fact-checks and captions come straight back.
    func testLeavingSubtitlesOnTheGlassesCanBeTheGesture() async {
        let b = bridge()
        b.enabled = true
        let exit = InmoCommand.closeModule(8)
        clock = clock.addingTimeInterval(5)                 // well after our own open
        b.learnGesture()
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(exit), raw: exit)
        XCTAssertNotNil(b.factCheckGesture)
        XCTAssertTrue(b.enabled)
        clock = clock.addingTimeInterval(5)
        let opensBefore = surface.calls.filter { $0 == "open" }.count
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(exit), raw: exit)
        for _ in 0..<100 where source.factChecks == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(source.factChecks, 1)
        XCTAssertTrue(b.enabled)
        XCTAssertEqual(surface.calls.filter { $0 == "open" }.count, opensBefore + 1)   // captions reopened
    }

    /// Holding GO opens Face Link (app 6). As the gesture, that app is closed
    /// again and captions come back on the lens; the lens leaving Subtitles
    /// meanwhile doesn't turn captions off.
    func testTheGOHoldGestureClosesItsAppAndBringsCaptionsBack() async {
        let b = bridge()
        b.reopenDelay = .zero
        b.enabled = true
        let hold = InmoCommand.openModule(6)
        clock = clock.addingTimeInterval(5)
        b.learnGesture()
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(hold), raw: hold)
        XCTAssertEqual(b.factCheckGesture, hold.map { String(format: "%02x", $0) }.joined())
        clock = clock.addingTimeInterval(10)
        posted = []
        let opensBefore = surface.calls.filter { $0 == "open" }.count
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(hold), raw: hold)
        let left = InmoCommand.closeModule(8)                // the lens left Subtitles
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(left), raw: left)
        for _ in 0..<100 where surface.calls.filter({ $0 == "open" }).count == opensBefore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(posted.first, InmoCommand.closeModule(6))
        XCTAssertEqual(surface.calls.filter { $0 == "open" }.count, opensBefore + 1)
        XCTAssertTrue(b.enabled)
        XCTAssertEqual(b.status, .showing)
    }

    /// Face Link isn't told "ready" for the app the gesture opened, so its camera
    /// never starts; a Face Link opened any other time is left alone.
    func testTheGestureAppIsKnownOnlyForAMoment() {
        let b = bridge()
        b.enabled = true
        let hold = InmoCommand.openModule(6)
        clock = clock.addingTimeInterval(5)
        b.learnGesture()
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(hold), raw: hold)
        XCTAssertTrue(b.gestureOpened(module: 6))
        XCTAssertFalse(b.gestureOpened(module: 5))
        clock = clock.addingTimeInterval(10)
        XCTAssertFalse(b.gestureOpened(module: 6))
    }

    /// Our own close echoes the same bytes: right after we close, it's not the gesture.
    func testOurOwnCloseEchoIsNotTheGesture() async {
        let b = bridge()
        b.enabled = true
        let exit = InmoCommand.closeModule(8)
        clock = clock.addingTimeInterval(5)
        b.learnGesture()
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(exit), raw: exit)
        clock = clock.addingTimeInterval(5)
        b.enabled = false                                   // we close app 8 now
        b.handleGlasses(type: 15, fields: try! InmoWireCodec.decode(exit), raw: exit)   // its echo
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.factChecks, 0)
    }

    /// The question and the answer are set apart by a divider line.
    func testQuestionAndAnswerHaveADividerBetweenThem() {
        let chunks = LiveLensBridge.frame(title: "Jarvis", parts: ["Q: Is this a fair price?", "A: It's a bit high."])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "━━━ 【Jarvis】 ━━━\nQ: Is this a fair price?\n"
                       + LiveLensBridge.blockDivider + "\nA: It's a bit high.\n" + LiveLensBridge.blockBar)
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