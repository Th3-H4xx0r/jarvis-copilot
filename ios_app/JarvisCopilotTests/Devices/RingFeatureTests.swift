import XCTest
@testable import JarvisCopilot

/// The decoded log, the inputs that drive custom actions, and probing what the ring answers.
@MainActor
final class RingFeatureTests: XCTestCase {

    private var link: FakeRingLink!
    private var session: RingSession!

    override func setUp() async throws {
        link = FakeRingLink()
        session = RingSession(transport: makeRingTransport(link))
    }

    // MARK: Log

    func testCommandsAndRepliesAreDescribedInWords() {
        let cases: [(RingFrame, String, String)] = [
            (RingFrame(outbound: true, channel: .command, cmd: 0x16, payload: [2, 1, 10]),
             "Set heart-rate monitoring", "on, every 10 min"),
            (RingFrame(outbound: false, channel: .command, cmd: 0x03, payload: [76, 1]),
             "Battery", "76%, charging"),
            (RingFrame(outbound: false, channel: .command, cmd: 0x73, payload: [45, 3]),
             "Ring input", "Tap"),
            (RingFrame(outbound: false, channel: .command, cmd: 0x69, payload: [1, 0, 61]),
             "Measurement", "heart rate: 61"),
            (RingFrame(outbound: true, channel: .bigData, cmd: 0x27, payload: [0, 1]),
             "Read sleep", ""),
        ]
        for (frame, title, detail) in cases {
            let described = RingLogDecoder.describe(frame)
            XCTAssertEqual(described.title, title)
            XCTAssertEqual(described.detail, detail)
        }
    }

    func testARejectedFrameSaysSo() {
        let frame = RingFrame(outbound: false, channel: .command, cmd: 0x21, payload: [1], isError: true)
        XCTAssertTrue(RingLogDecoder.describe(frame).detail.contains("rejected"))
    }

    func testTheLogKeepsNewestFirstAndTakesNotes() {
        let log = RingLog()
        log.record(RingFrame(outbound: true, channel: .command, cmd: 0x50, payload: [0x55, 0xAA]))
        log.note("Ring input: Tap", "Torch on")

        XCTAssertEqual(log.entries.first?.title, "Ring input: Tap")
        XCTAssertEqual(log.entries.first?.detail, "Torch on")
        XCTAssertEqual(log.entries.last?.title, "Find ring")
    }

    // MARK: Inputs

    func testTheRingsCodesMapToInputs() {
        XCTAssertEqual(RingInput(musicAction: 1), .tap)
        XCTAssertEqual(RingInput(musicAction: 3), .swipeForward)
        XCTAssertEqual(RingInput(musicAction: 5), .volumeDown)
        XCTAssertNil(RingInput(musicAction: 9))
        XCTAssertEqual(RingInput(touchKey: 4), .longPress)
        XCTAssertEqual(RingInput(touchKey: 3), .tap)
    }

    func testEveryChannelTheRingPressesOnBecomesAnInput() async throws {
        session.pressWindow = 0.05
        session.wantsMultiPress = { true }
        var seen: [RingInput] = []
        session.onInput = { seen.append($0) }

        link.deliver(RingProtocol.frame(0x1D, [3]))       // music mode (Android only)
        link.deliver(RingProtocol.frame(0x73, [45, 4]))   // key event
        link.deliver(RingProtocol.frame(0x73, [48]))      // couple double-tap
        link.deliver(RingProtocol.frame(0x73, [41]))      // game click
        try await Task.sleep(nanoseconds: 120_000_000)
        link.deliver(RingProtocol.frame(0x73, [37, 0, 0, 0, 5]))  // tasbih counter
        link.deliver(RingProtocol.frame(0x02, [1]))       // camera shutter
        try await Task.sleep(nanoseconds: 120_000_000)

        // Presses are grouped, so the two that land together are one double press.
        XCTAssertEqual(seen, [.swipeForward, .longPress, .doubleTap, .tap, .doublePress])
    }

    func testPressesInQuickSuccessionMakeThreeInputsFromOneGesture() async throws {
        session.pressWindow = 0.05
        session.wantsMultiPress = { true }
        var seen: [RingInput] = []
        session.onInput = { seen.append($0) }

        for _ in 0..<3 { link.deliver(RingProtocol.frame(0x73, [41])) }
        try await Task.sleep(nanoseconds: 120_000_000)
        link.deliver(RingProtocol.frame(0x73, [41]))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(seen, [.triplePress, .tap])
    }

    func testASinglePressRunsAtOnceWhenNothingUsesMultiPress() async throws {
        session.pressWindow = 1.4
        session.wantsMultiPress = { false }
        var seen: [RingInput] = []
        session.onInput = { seen.append($0) }

        link.deliver(RingProtocol.frame(0x73, [41]))
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(seen, [.tap], "no waiting when there is nothing to disambiguate")
    }

    func testMultiPressIsOnlyCountedWhenSomethingIsBoundToIt() {
        let defaults = UserDefaults(suiteName: "RingFeatureTests.multi")!
        defaults.removePersistentDomain(forName: "RingFeatureTests.multi")
        let store = RingInputStore(deviceID: "ring-3", defaults: defaults)
        XCTAssertFalse(store.usesMultiPress)

        store.set(.skill(id: "flashlight_on", arguments: [:]), for: .tap)
        XCTAssertFalse(store.usesMultiPress, "a single-press action alone needs no window")

        store.set(.skill(id: "vibrate", arguments: [:]), for: .doublePress)
        XCTAssertTrue(store.usesMultiPress)
    }

    func testOnlyTheGesturesTheRingHasAreOffered() {
        XCTAssertEqual(RingInput.available(touchSurface: false), [.tap, .doublePress, .triplePress])
        XCTAssertTrue(RingInput.available(touchSurface: true).contains(.swipeForward))
    }

    func testActionsSurviveARelaunchAndOnlyCountWhenSet() {
        let defaults = UserDefaults(suiteName: "RingFeatureTests.inputs")!
        defaults.removePersistentDomain(forName: "RingFeatureTests.inputs")
        let store = RingInputStore(deviceID: "ring-1", defaults: defaults)
        XCTAssertFalse(store.isConfigured)

        store.set(.prompt("turn off the lights"), for: .tap)
        store.set(.skill(id: "open_app", arguments: ["app": "spotify"]), for: .longPress)

        let restored = RingInputStore(deviceID: "ring-1", defaults: defaults)
        XCTAssertTrue(restored.isConfigured)
        XCTAssertEqual(restored.action(for: .tap).summary, "Ask Jarvis: turn off the lights")
        XCTAssertEqual(restored.action(for: .longPress).summary, "Open an app: spotify")
        XCTAssertEqual(restored.action(for: .swipeBack), .none)
    }

    func testEveryCatalogueActionNamesASkill() {
        for option in RingActionCatalogue.options {
            XCTAssertFalse(option.skill.isEmpty, "\(option.id) has no skill")
            if let parameter = option.parameter {
                XCTAssertFalse(parameter.title.isEmpty, "\(option.id) parameter has no title")
            }
        }
        XCTAssertEqual(Set(RingActionCatalogue.options.map(\.id)).count, RingActionCatalogue.options.count)
    }

    // MARK: Probe

    func testProbingRecordsWhatTheRingAnswersAndBeatsTheFlags() async {
        // Flags say no temperature and no new sleep protocol; the ring answers both anyway.
        session.setCapabilities(RingCapabilities(blockA: [UInt8](repeating: 0, count: 14),
                                                 blockB: [UInt8](repeating: 0, count: 14)))
        link.script(0x27, on: .bigData, [RingProtocol.bigDataFrame(0x27, [0])])
        link.script(0x77, on: .bigData, [RingProtocol.bigDataFrame(0x77, [0, 5, 1, 0, 100])])
        link.script(0x43, [RingProtocol.frame(0x43, [0xFF])])

        await session.runProbe()

        XCTAssertEqual(session.probe.works(.sleep), true)
        XCTAssertEqual(session.probe.works(.temperature), true)
        XCTAssertEqual(session.probe.works(.stepSlots), true)
        XCTAssertEqual(session.probe.works(.hrv), false, "nothing answered 0x39")
        XCTAssertTrue(session.supports(.temperature), "the answer wins over the flag")
        XCTAssertFalse(session.supports(.hrv))
    }

    func testAProbeIsNotRepeatedUntilTheFirmwareChanges() async {
        link.script(0x43, [RingProtocol.frame(0x43, [0xFF])])
        await session.runProbe()
        let sent = link.sentCommands.count
        XCTAssertGreaterThan(sent, 0)

        await session.runProbe()
        XCTAssertEqual(link.sentCommands.count, sent, "the second run is skipped")

        session.setRevision(firmware: "3.10.07", hardware: nil)
        await session.runProbe()
        XCTAssertGreaterThan(link.sentCommands.count, sent, "new firmware re-checks")
    }
}
