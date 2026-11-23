import XCTest
@testable import JarvisCopilot

/// Incoming phone calls on the simulated Ray-Ban Meta (Gen 2), as pure rules: the call's states,
/// the 30 s ring before it's missed, what ends it, and what it costs.
final class MetaCallStateTests: XCTestCase {

    func testRingAnswerThenHangUp() {
        var hw = MetaHardwareState()
        XCTAssertEqual(hw.call, .none)
        XCTAssertNil(hw.ring(from: "Mom"))
        XCTAssertEqual(hw.call, .ringing(from: "Mom", seconds: 0))
        XCTAssertEqual(hw.answerCall(), "Mom")
        XCTAssertEqual(hw.call, .active(from: "Mom", seconds: 0))
        _ = hw.tick(65, speed: 60)
        XCTAssertEqual(hw.call, .active(from: "Mom", seconds: 65), "the call timer runs in real time, not sim speed")
        let ended = hw.hangUp()
        XCTAssertEqual(ended?.caller, "Mom")
        XCTAssertEqual(ended?.seconds ?? 0, 65, accuracy: 0.001)
        XCTAssertEqual(hw.call, .none)
    }

    func testDeclineEndsARingingCall() {
        var hw = MetaHardwareState()
        hw.ring(from: "Mom")
        XCTAssertEqual(hw.rejectCall(), "Mom")
        XCTAssertEqual(hw.call, .none)
    }

    func testEachStepOnlyAppliesInItsState() {
        var hw = MetaHardwareState()
        XCTAssertNil(hw.answerCall(), "nothing to answer")
        XCTAssertNil(hw.rejectCall())
        XCTAssertNil(hw.hangUp())
        hw.ring(from: "Mom")
        XCTAssertNil(hw.hangUp(), "a ringing call is declined, not hung up")
        hw.answerCall()
        XCTAssertNil(hw.rejectCall(), "an answered call is hung up, not declined")
        XCTAssertNil(hw.answerCall())
        XCTAssertEqual(hw.ring(from: "Dad"), "Already on a call", "no call waiting in the sim")
        XCTAssertEqual(hw.call.caller, "Mom")
    }

    func testAnUnnamedCallerIsUnknown() {
        var hw = MetaHardwareState()
        hw.ring(from: "   ")
        XCTAssertEqual(hw.call.caller, "Unknown caller")
    }

    func testMissedAfterThirtySecondsOfRinging() {
        var hw = MetaHardwareState()
        hw.ring(from: "Mom")
        XCTAssertTrue(hw.tick(29, speed: 60).isEmpty, "sim speed doesn't hurry the caller")
        XCTAssertTrue(hw.call.isRinging)
        let events = hw.tick(1.5)
        XCTAssertEqual(events, [.callMissed(from: "Mom")])
        XCTAssertEqual(hw.call, .none)
        XCTAssertEqual(MetaGen2Profile.callRingSeconds, 30)
    }

    func testTheGlassesOnlyRingWhenTheyCan() {
        let cases: [(String, (inout MetaHardwareState) -> Void, String)] = [
            ("range", { $0.inRange = false }, "out of range"),
            ("battery", { $0.battery = 0 }, "battery is empty"),
            ("case", { $0.inCase = true }, "in their case"),
            ("folded", { $0.folded = true }, "folded"),
        ]
        for (name, apply, expected) in cases {
            var hw = MetaHardwareState()
            apply(&hw)
            let why = hw.ring(from: "Mom")
            XCTAssertTrue(why?.contains(expected) == true, "\(name): got \(String(describing: why))")
            XCTAssertEqual(hw.call, .none, name)
        }
    }

    func testGlassesOffInTheCaseOrOutOfRangeEndTheCall() {
        let cases: [(String, (inout MetaHardwareState) -> Void, String)] = [
            ("range", { $0.inRange = false }, "Out of range"),
            ("case", { $0.inCase = true }, "Put in the case"),
            ("folded", { $0.folded = true }, "Folded"),
            ("battery", { $0.battery = 0 }, "Battery empty"),
        ]
        for (name, apply, reason) in cases {
            for answered in [false, true] {
                var hw = MetaHardwareState()
                hw.ring(from: "Mom")
                if answered { hw.answerCall() }
                apply(&hw)
                let events = hw.applyPhysicalChange()
                XCTAssertEqual(events, [.callEnded(reason: reason, wasRinging: !answered)], name)
                XCTAssertEqual(hw.call, .none, name)
            }
        }
    }

    func testTheBatteryRunningOutEndsTheCall() {
        var hw = MetaHardwareState()
        hw.battery = 0.05
        hw.ring(from: "Mom")
        hw.answerCall()
        let events = hw.tick(60)
        XCTAssertTrue(events.contains(.callEnded(reason: "Battery empty", wasRinging: false)))
        XCTAssertEqual(hw.call, .none)
    }

    func testTakingThemOffKeepsTheCall() {
        var hw = MetaHardwareState()
        hw.ring(from: "Mom")
        hw.answerCall()
        hw.worn = false
        XCTAssertTrue(hw.applyPhysicalChange().isEmpty)
        XCTAssertTrue(hw.call.isActive)
    }

    func testACallDrainsLikeAudioPlayback() {
        var idle = MetaHardwareState()
        _ = idle.tick(60)
        var onCall = MetaHardwareState()
        onCall.ring(from: "Mom")
        onCall.answerCall()
        _ = onCall.tick(60)
        XCTAssertEqual(100 - onCall.battery, MetaGen2Profile.drainMusic, accuracy: 0.0001)
        XCTAssertGreaterThan(100 - onCall.battery, 100 - idle.battery)
    }

    func testRingingPausesTheMusic() {
        var hw = MetaHardwareState()
        hw.musicPlaying = true
        hw.ring(from: "Mom")
        XCTAssertFalse(hw.musicPlaying, "the phone holds its media for the call")
    }

    func testTheAssistantIsOffWhileACallRingsOrIsOn() {
        var hw = MetaHardwareState()
        XCTAssertNil(hw.voiceRefusal())
        hw.ring(from: "Mom")
        XCTAssertEqual(hw.voiceRefusal(), MetaCallRules.ringingReason)
        hw.answerCall()
        XCTAssertEqual(hw.voiceRefusal(), MetaCallRules.onCallReason)
        hw.inRange = false
        XCTAssertEqual(hw.voiceRefusal(), "The glasses are out of range", "the link problem is named first")
    }
}

/// The touchpad and the voice while a call rings or is on.
final class MetaCallRulesTests: XCTestCase {

    func testGesturesWhileRinging() {
        let ringing = MetaPhoneCall.ringing(from: "Mom", seconds: 3)
        XCTAssertEqual(MetaCallRules.touch(.doubleTap, during: ringing), .call(.answer))
        XCTAssertEqual(MetaCallRules.touch(.hold, during: ringing), .call(.reject), "hold declines instead of opening the assistant")
        XCTAssertEqual(MetaCallRules.touch(.tap, during: ringing), .ignored)
        XCTAssertEqual(MetaCallRules.touch(.tripleTap, during: ringing), .ignored)
        XCTAssertNil(MetaCallRules.touch(.swipeForward, during: ringing), "swipes still set the volume")
        XCTAssertNil(MetaCallRules.touch(.swipeBackward, during: ringing))
    }

    func testGesturesDuringACall() {
        let active = MetaPhoneCall.active(from: "Mom", seconds: 12)
        XCTAssertEqual(MetaCallRules.touch(.doubleTap, during: active), .call(.hangUp))
        XCTAssertEqual(MetaCallRules.touch(.hold, during: active), .refused(MetaCallRules.onCallReason))
        XCTAssertEqual(MetaCallRules.touch(.tap, during: active), .ignored)
        XCTAssertNil(MetaCallRules.touch(.swipeForward, during: active))
    }

    func testNoCallLeavesEveryGestureAlone() {
        for gesture in MetaTouchGesture.allCases {
            XCTAssertNil(MetaCallRules.touch(gesture, during: .none), gesture.rawValue)
            XCTAssertNil(MetaCallRules.label(gesture, during: .none), gesture.rawValue)
        }
    }

    func testTheTouchpadSaysWhatAGestureDoesNow() {
        XCTAssertEqual(MetaCallRules.label(.doubleTap, during: .ringing(from: "Mom", seconds: 0)), "Answer")
        XCTAssertEqual(MetaCallRules.label(.hold, during: .ringing(from: "Mom", seconds: 0)), "Decline")
        XCTAssertEqual(MetaCallRules.label(.doubleTap, during: .active(from: "Mom", seconds: 0)), "Hang up")
        XCTAssertNil(MetaCallRules.label(.swipeForward, during: .active(from: "Mom", seconds: 0)))
    }

    func testVoiceAnswers() {
        for said in ["answer", "Answer it.", "pick up", "Pick it up", "yes", "Yes please", "yeah", "accept",
                     "Hey Jarvis, answer", "hey meta answer"] {
            XCTAssertEqual(MetaCallRules.voiceCommand(said), .answer, said)
        }
    }

    func testVoiceDeclines() {
        for said in ["reject", "Decline", "decline the call", "no", "No thanks", "nope",
                     "don't answer", "Do not pick up", "Hey Meta, reject"] {
            XCTAssertEqual(MetaCallRules.voiceCommand(said), .reject, said)
        }
    }

    func testAnythingElseIsntACallCommand() {
        for said in ["", "what's the weather", "yesterday", "nobody knows", "I know", "answered",
                     "yes no", "answer, no decline"] {
            XCTAssertNil(MetaCallRules.voiceCommand(said), said)
        }
    }

    func testCallClock() {
        XCTAssertEqual(MetaCallRules.clock(0), "0:00")
        XCTAssertEqual(MetaCallRules.clock(7.9), "0:07")
        XCTAssertEqual(MetaCallRules.clock(65), "1:05")
        XCTAssertEqual(MetaCallRules.clock(3_723), "1:02:03")
    }
}

/// The simulated glasses taking a call: announce, chime, gestures, voice, feed, and what Jarvis sees.
@MainActor
final class MetaGlassesCallSimTests: XCTestCase {
    @MainActor final class FakeSpeaker: MetaSpeaker {
        var said: [String] = []
        func say(_ text: String, volume: Int) { said.append(text) }
    }
    final class FakeEarcon: EarconPlaying {
        var played: [VoiceEarcon] = []
        func play(_ earcon: VoiceEarcon) -> Int { played.append(earcon); return 0 }
    }
    @MainActor final class FakeCapture: MetaQuestionCapturing {
        var asked = false
        func captureQuestion(beforeRelease: (() -> Int)?) async throws -> Data { asked = true; return Data(count: 32_000) }
    }

    private struct Rig {
        let sim: SimulatedGlassesTransport
        let device: MetaGlassesDevice
        let speaker: FakeSpeaker
        let chime: FakeEarcon
        let earcon: FakeEarcon
        let capture: FakeCapture
    }

    private func makeRig() async throws -> Rig {
        let sim = SimulatedGlassesTransport(autoTick: false)
        let speaker = FakeSpeaker()
        let chime = FakeEarcon()
        let earcon = FakeEarcon()
        let capture = FakeCapture()
        sim.speaker = speaker
        sim.ringChime = chime
        sim.earcon = earcon
        sim.questionCapture = capture
        sim.ringInterval = .milliseconds(20)
        let name = "meta-call-\(UUID().uuidString)"
        let device = MetaGlassesDevice(transport: sim, voice: FakeVoiceTurnController(), feed: sim.feed,
                                       defaults: UserDefaults(suiteName: name)!)
        try await device.session.start()
        return Rig(sim: sim, device: device, speaker: speaker, chime: chime, earcon: earcon, capture: capture)
    }

    /// Let the session's pump drain whatever the glasses reported.
    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    func testRingAnnouncesTheCallerThenChimesSoftlyUntilAnswered() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        XCTAssertEqual(rig.sim.hw.call, .ringing(from: "Mom", seconds: 0))
        XCTAssertEqual(rig.sim.focus, MetaGlassesFocus(part: .speakers, pulse: .speaking))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.speaker.said, ["Call from Mom"], "announced through the glasses' speakers")
        XCTAssertGreaterThanOrEqual(rig.chime.played.count, 2, "the soft chime repeats while it rings")
        XCTAssertTrue(rig.chime.played.allSatisfy { $0 == .listening }, "his listening chime, never a new tone")
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Incoming call from Mom")

        let track = rig.sim.track
        await rig.sim.touch(.doubleTap)
        XCTAssertEqual(rig.sim.hw.call, .active(from: "Mom", seconds: 0))
        XCTAssertEqual(rig.sim.track, track, "double-tap answered instead of skipping the track")
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Answered the call")
        let chimes = rig.chime.played.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.chime.played.count, chimes, "the chime stops once answered")
        await settle()
        XCTAssertNil(rig.device.session.lastTouchGesture, "the call gesture overrides Jarvis's touch binding")
    }

    func testHoldDeclinesInsteadOfOpeningTheAssistant() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        await rig.sim.touch(.hold)
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Declined the call")
        XCTAssertFalse(rig.capture.asked, "the assistant didn't open")
        XCTAssertTrue(rig.earcon.played.isEmpty)
        XCTAssertNil(rig.sim.focus)
        await settle()
        XCTAssertEqual(rig.device.session.wakeCount, 0)
        XCTAssertNil(rig.device.session.lastTouchGesture)
    }

    func testDuringACallDoubleTapHangsUpAndTheAssistantIsOff() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        await rig.sim.touch(.doubleTap)
        await rig.sim.advance(seconds: 65)

        await rig.sim.touch(.hold)
        XCTAssertFalse(rig.capture.asked, "the mic belongs to the call")
        XCTAssertEqual(rig.sim.feed.entries.first?.outcome, .refused(MetaCallRules.onCallReason))
        do {
            _ = try await rig.device.invoke("meta_glasses_talk", args: [:])
            XCTFail("Jarvis can't open the assistant during a call")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("On a call"), error.localizedDescription)
        }
        rig.sim.wake()
        XCTAssertEqual(rig.sim.feed.entries.first?.outcome, .refused(MetaCallRules.onCallReason), "the wake word is off too")

        let volume = rig.sim.hw.volume
        await rig.sim.touch(.swipeBackward)
        XCTAssertEqual(rig.sim.hw.volume, volume - 10, "swipes still set the call volume")
        await rig.sim.touch(.tap)
        XCTAssertFalse(rig.sim.hw.musicPlaying, "no music during a call")

        await rig.sim.touch(.doubleTap)
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Hung up")
        XCTAssertEqual(rig.sim.feed.entries.first?.detail, "Mom · 1:05")
        XCTAssertNil(rig.sim.focus)
    }

    func testUnansweredCallIsMissedAfterThirtySeconds() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        await rig.sim.advance(seconds: 29)
        XCTAssertTrue(rig.sim.hw.call.isRinging)
        await rig.sim.advance(seconds: 1.5)
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Missed call from Mom")
        let chimes = rig.chime.played.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.chime.played.count, chimes, "no chime after the caller gave up")
        XCTAssertNil(rig.sim.focus)
    }

    func testVoiceWhileRingingAnswersAndNeverReachesJarvis() async throws {
        let rig = try await makeRig()
        var heard: [Data] = []
        rig.sim.callTranscriber = { pcm in heard.append(pcm); return "Hey Jarvis, pick up" }
        rig.sim.ring(from: "Mom")
        let action = await rig.sim.hearDuringCall(Data(count: 16_000))
        XCTAssertEqual(action, .answer)
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(rig.sim.hw.call.isActive)
        XCTAssertEqual(rig.sim.feed.entries.first?.source, .voice)
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Answered the call")
        await settle()
        XCTAssertEqual(rig.device.session.wakeCount, 0, "nothing went to Jarvis")
    }

    func testVoiceDeclinesAndOtherWordsKeepItRinging() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        XCTAssertNil(rig.sim.hearDuringCall(text: "what's the weather"))
        XCTAssertTrue(rig.sim.hw.call.isRinging)
        XCTAssertEqual(rig.sim.feed.entries.first?.title, "Didn't catch that")
        XCTAssertEqual(rig.sim.hearDuringCall(text: "decline"), .reject)
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertNil(rig.sim.hearDuringCall(text: "answer"), "nothing to answer any more")
        await settle()
        XCTAssertEqual(rig.device.session.wakeCount, 0)
    }

    func testRingRefusedWhenTheGlassesCantRing() async throws {
        let rig = try await makeRig()
        await rig.sim.setInCase(true)
        rig.sim.ring(from: "Mom")
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertEqual(rig.sim.feed.entries.first?.outcome, .refused("The glasses are in their case"))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(rig.speaker.said.isEmpty, "only the phone rings")
        XCTAssertTrue(rig.chime.played.isEmpty)
    }

    func testOutOfRangeTakesTheCallOffTheGlasses() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        await rig.sim.touch(.doubleTap)
        await rig.sim.setInRange(false)
        XCTAssertEqual(rig.sim.hw.call, .none)
        XCTAssertTrue(rig.sim.feed.entries.contains { $0.title == "Call left the glasses" })
    }

    func testJarvisSeesOnlyWhetherACallIsOnNeverWhoOrAnyControl() async throws {
        let rig = try await makeRig()
        var status = try await rig.device.invoke("meta_glasses_status", args: [:])
        XCTAssertEqual(status["phone_call"] as? String, "none")
        rig.sim.ring(from: "Aunt Zelda")
        status = try await rig.device.invoke("meta_glasses_status", args: [:])
        XCTAssertEqual(status["phone_call"] as? String, "ringing")
        XCTAssertFalse(String(describing: status).contains("Zelda"), "iOS gives apps no caller identity")
        await rig.sim.touch(.doubleTap)
        status = try await rig.device.invoke("meta_glasses_status", args: [:])
        XCTAssertEqual(status["phone_call"] as? String, "active")
        XCTAssertFalse(String(describing: rig.device.snapshot()).contains("Zelda"))

        XCTAssertEqual(rig.device.capabilities.map(\.name), MetaGlassesDevice.capabilityNames, "no call tool added")
        XCTAssertFalse(rig.device.capabilities.contains { cap in
            ["call", "answer", "decline", "hang"].contains { cap.name.contains($0) }
        })
        do {
            _ = try await rig.device.invoke("meta_glasses_call", args: ["action": "hang_up"])
            XCTFail("the real glasses give Jarvis no call control")
        } catch {}
        XCTAssertTrue(rig.sim.hw.call.isActive)
    }

    func testTheHandsFreeListenerStaysOffDuringACall() {
        func gate(onCall: Bool) -> Bool {
            MetaSimWakeListener.shouldListen(onScreen: true, appActive: true, switchOn: true, enrolled: true,
                                             turnRunning: false, pressing: false, handingOff: false,
                                             capturingQuestion: false, assistantBusy: false, jarvisSpeaking: false,
                                             onCall: onCall)
        }
        XCTAssertTrue(gate(onCall: false))
        XCTAssertFalse(gate(onCall: true), "the mic belongs to the call")
    }

    func testDisconnectEndsTheRinging() async throws {
        let rig = try await makeRig()
        rig.sim.ring(from: "Mom")
        await rig.device.session.stop()
        XCTAssertEqual(rig.sim.hw.call, .none)
        let chimes = rig.chime.played.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.chime.played.count, chimes)
    }

    // MARK: Real calls (FaceTime crash, 2026-11-22)

    func testTheWakeListenerNeverTapsAMicWithNoRateOrChannels() {
        XCTAssertFalse(MetaSimWakeListener.micFormatUsable(sampleRate: 0, channels: 0), "a call holds the mic")
        XCTAssertFalse(MetaSimWakeListener.micFormatUsable(sampleRate: 48_000, channels: 0))
        XCTAssertFalse(MetaSimWakeListener.micFormatUsable(sampleRate: 0, channels: 1))
        XCTAssertTrue(MetaSimWakeListener.micFormatUsable(sampleRate: 48_000, channels: 1))
    }

    func testARealCallKeepsTheWakeListenerOff() {
        XCTAssertFalse(MetaSimWakeListener.shouldListen(onScreen: true, appActive: true, switchOn: true, enrolled: true,
                                                        turnRunning: false, pressing: false, handingOff: false,
                                                        capturingQuestion: false, assistantBusy: false, jarvisSpeaking: false,
                                                        onCall: true))
    }
}
