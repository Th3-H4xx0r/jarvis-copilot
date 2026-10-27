import XCTest
@testable import JarvisCopilot

/// "Talk to JARVIS here" (the Action button): a talk in place, a stop, or Jarvis
/// opened listening when it can't start in the background.
@MainActor
final class TalkHereTests: XCTestCase {
    private final class FakeVoice: TalkHereVoice {
        var isActive = false
        var starts = true
        var goesLive = true
        private(set) var started = 0
        private(set) var stopped = 0

        private(set) var inBackground: [Bool] = []

        func startOneShotTurn(inBackground: Bool) async -> Bool {
            started += 1
            self.inBackground.append(inBackground)
            if starts { isActive = true }
            return starts
        }

        func waitUntilCapturing(timeout: TimeInterval) async -> Bool { goesLive }

        func stopTalk() async {
            stopped += 1
            isActive = false
        }
    }

    private func make(foreground: Bool = false) -> (TalkHere, FakeVoice, FakeLiveActivityCoordinator, ServiceRecorder) {
        let voice = FakeVoice()
        let log = ServiceRecorder()
        let island = FakeLiveActivityCoordinator(log)
        return (TalkHere(voice: voice, isForeground: { foreground }, island: island), voice, island, log)
    }

    func testAPressInTheBackgroundTalksInPlaceWithTheIslandPresented() async {
        let (talk, voice, island, log) = make()
        let outcome = await talk.press()
        XCTAssertEqual(outcome, .listening)
        XCTAssertEqual(voice.started, 1)
        XCTAssertEqual(voice.inBackground, [true], "the session that needs no switch from the background")
        XCTAssertTrue(log.contains("liveActivity.present"))
        XCTAssertTrue(island.voiceReports.isEmpty, "the turn's own frames drive the island")
    }

    func testTheFirstPressArmsTheRecordReadyKeepalive() async {
        let voice = FakeVoice()
        var arms = 0
        let talk = TalkHere(voice: voice, isForeground: { true }, island: FakeLiveActivityCoordinator(ServiceRecorder()),
                            arm: { arms += 1 })
        _ = await talk.press()
        XCTAssertEqual(arms, 1, "even a press that opens Jarvis arms it, so the next one can stay put")
    }

    func testASecondPressStops() async {
        let (talk, voice, _, _) = make()
        _ = await talk.press()
        let outcome = await talk.press()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(voice.stopped, 1)
        XCTAssertEqual(voice.started, 1)
    }

    func testAPressWithJarvisOnScreenOpensItsVoiceScreen() async {
        let (talk, voice, _, log) = make(foreground: true)
        let outcome = await talk.press()
        XCTAssertEqual(outcome, .needsApp)
        XCTAssertEqual(voice.started, 0)
        XCTAssertFalse(log.contains("liveActivity.present"))
    }

    func testARefusedMicOpensJarvisListeningAndClearsTheIsland() async {
        let (talk, voice, island, _) = make()
        voice.starts = false
        let outcome = await talk.press()
        XCTAssertEqual(outcome, .needsApp)
        XCTAssertEqual(island.voiceReports.map(\.state), ["idle"])
    }

    func testAMicThatNeverComesUpStopsTheTurnAndOpensJarvis() async {
        let (talk, voice, island, _) = make()
        voice.goesLive = false
        let outcome = await talk.press()
        XCTAssertEqual(outcome, .needsApp)
        XCTAssertEqual(voice.stopped, 1, "no half-started turn left holding the mic")
        XCTAssertFalse(voice.isActive)
        XCTAssertEqual(island.voiceReports.map(\.state), ["idle"])
    }
}
