import AVFoundation
import XCTest
@testable import JarvisCopilot

/// The Gen 2 limits as pure rules (`MetaHardwareState`).
final class MetaHardwareStateTests: XCTestCase {

    func testStreamingDrainsWithinSourcedRange() {
        var hw = MetaHardwareState()
        hw.streaming = true
        _ = hw.tick(60)
        let drained = 100 - hw.battery
        XCTAssertGreaterThanOrEqual(drained, 1.2, "streaming drains 1.2–2 %/min (research doc)")
        XCTAssertLessThanOrEqual(drained, 2.0)
    }

    func testCaseChargesFiftyPercentInTwentyMinutes() {
        var hw = MetaHardwareState()
        hw.battery = 10
        hw.inCase = true
        _ = hw.tick(20 * 60)
        XCTAssertEqual(hw.battery, 60, accuracy: 1.0, "50 % in 20 min")
        XCTAssertLessThan(hw.caseBattery, 100, "the case paid for it")
        XCTAssertEqual(100 - hw.caseBattery, 50 / MetaGen2Profile.caseChargesFull, accuracy: 0.5)
    }

    func testSpeedScalesBatteryButNotClipTime() {
        var hw = MetaHardwareState()
        hw.musicPlaying = true
        hw.startRecording(seconds: 30)
        _ = hw.tick(10, speed: 60)
        XCTAssertEqual(hw.recording?.elapsed ?? -1, 10, accuracy: 0.001, "a clip still records in real time")
        XCTAssertLessThan(hw.battery, 100 - 10.0 * 60 / 60 * MetaVideoMode.uhd3K30.drainPerMinute + 0.5)
    }

    func testSustained3KOverheatsThenCools() {
        var hw = MetaHardwareState()
        hw.recording = .init(mode: .uhd3K30, cap: 3_600)
        var overheatedAt: Int?
        var stopReason: String?
        for second in 1 ... 25 * 60 {
            for event in hw.tick(1) {
                if case .cameraTooHot = event { overheatedAt = second }
                if case .recordingStopped(_, let reason) = event { stopReason = reason }
            }
            if overheatedAt != nil { break }
        }
        let minutes = Double(overheatedAt ?? 0) / 60
        XCTAssertGreaterThan(minutes, 12, "3K runs ~15 min before the camera cuts out")
        XCTAssertLessThan(minutes, 18)
        XCTAssertEqual(stopReason, "Too hot")
        XCTAssertNotNil(hw.captureRefusal(), "camera off while too hot")

        var cooledAfter: Int?
        for second in 1 ... 10 * 60 {
            if hw.tick(1).contains(.cameraCooled) { cooledAfter = second; break }
        }
        let cool = Double(cooledAfter ?? 0) / 60
        XCTAssertGreaterThanOrEqual(cool, 2.5, "rest 3–5 minutes")
        XCTAssertLessThanOrEqual(cool, 5.5)
        XCTAssertNil(hw.captureRefusal())
    }

    func testStorageFullRefusesCapture() {
        var hw = MetaHardwareState()
        hw.storageUsed = MetaGen2Profile.storageUsableBytes - 1_000
        XCTAssertEqual(hw.captureRefusal(), "Glasses storage is full — import to the phone first")
    }

    func testClipCapClampsToSetting() {
        var hw = MetaHardwareState()
        hw.clipLength = 60
        XCTAssertEqual(hw.clipSeconds(requested: 180), 60)
        XCTAssertEqual(hw.clipSeconds(requested: nil), 60)
        XCTAssertEqual(hw.clipSeconds(requested: 12), 12)
        XCTAssertEqual(MetaGen2Profile.clipLengths.max(), 180, "3 min max")
    }

    func testRefusalOrderAndLowBattery() {
        var hw = MetaHardwareState()
        hw.battery = 9
        XCTAssertTrue(hw.captureRefusal()?.contains("Battery too low") == true)
        XCTAssertNil(hw.voiceRefusal(), "the assistant still works at 9 %")
        hw.ledCovered = true
        XCTAssertTrue(hw.captureRefusal()?.contains("LED is covered") == true, "a covered LED is named before battery")
        hw.inRange = false
        XCTAssertEqual(hw.captureRefusal(), "The glasses are out of range")
    }

    func testRecordingStopsAtClipCapAndStoresIt() {
        var hw = MetaHardwareState()
        hw.startRecording(seconds: 5)
        let events = hw.tick(6)
        XCTAssertTrue(events.contains(.recordingStopped(seconds: 5, reason: "Reached the 5 s clip length")))
        XCTAssertNil(hw.recording)
        XCTAssertEqual(hw.videoCount, 1)
        XCTAssertEqual(hw.storageUsed, Int64(MetaVideoMode.uhd3K30.bytesPerSecond * 5))
    }
}

/// The simulated glasses as a transport: commands, refusals, physical changes, touch.
@MainActor
final class MetaGlassesSimulatorHardwareTests: XCTestCase {

    private func makeSim() async throws -> SimulatedGlassesTransport {
        let sim = SimulatedGlassesTransport(autoTick: false)
        sim.transferTimeScale = 0
        try await sim.connect()
        return sim
    }

    private func nextEvent(_ sim: SimulatedGlassesTransport, timeout: Duration = .seconds(2),
                           where match: @escaping (GlassesInboundEvent) -> Bool) async -> GlassesInboundEvent? {
        let stream = sim.inbound
        let task = Task { () -> GlassesInboundEvent? in
            for await event in stream where match(event) { return event }
            return nil
        }
        let timer = Task { try? await Task.sleep(for: timeout); task.cancel() }
        let result = await task.value
        timer.cancel()
        return result
    }

    private func refusal(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil }
        catch MetaGlassesError.refused(let why) { return why }
        catch { return "unexpected: \(error)" }
    }

    func testEveryLimitRefusesAPhotoWithTheGlassesReason() async throws {
        let cases: [(String, (SimulatedGlassesTransport) async -> Void, String)] = [
            ("LED", { await $0.setLEDCovered(true) }, "capture LED is covered"),
            ("folded", { await $0.setFolded(true) }, "folded"),
            ("case", { await $0.setInCase(true) }, "in their case"),
            ("battery", { await $0.overrideBattery(5) }, "Battery too low"),
            ("heat", { await $0.overrideHeat(0.95) }, "too hot"),
            ("range", { await $0.setInRange(false) }, "out of range"),
        ]
        for (name, apply, expected) in cases {
            let sim = try await makeSim()
            await apply(sim)
            let why = await refusal { try await sim.send(.capturePhoto(question: nil)) }
            XCTAssertTrue(why?.contains(expected) == true, "\(name): got \(String(describing: why))")
            XCTAssertTrue(sim.feed.entries.contains { if case .refused = $0.outcome { return true }; return false },
                          "\(name): the refusal is in the feed")
            XCTAssertTrue(sim.storage.isEmpty)
        }
    }

    func testPhotoStoresOnTheGlassesAndReportsIt() async throws {
        let sim = try await makeSim()
        try await sim.send(.capturePhoto(question: "what is this"))
        XCTAssertEqual(sim.hw.photoCount, 1)
        XCTAssertEqual(sim.storage.first?.kind, .photo)
        XCTAssertEqual(sim.feed.entries.first?.title, "Photo")
        XCTAssertNotNil(sim.feed.entries.first?.thumbnail)
    }

    func testCoveringTheLEDStopsARecording() async throws {
        let sim = try await makeSim()
        try await sim.send(.startVideo(seconds: 30))
        XCTAssertTrue(sim.ledLit)
        await sim.advance(seconds: 3)
        async let clip = nextEvent(sim) { if case .video = $0 { return true }; return false }
        await sim.setLEDCovered(true)
        guard case .video(let recorded)? = await clip else { return XCTFail("no clip reported") }
        XCTAssertEqual(recorded.stopReason, "Capture LED covered")
        XCTAssertEqual(recorded.seconds, 3, accuracy: 0.01)
        XCTAssertNil(sim.hw.recording)
        XCTAssertFalse(sim.ledLit)
    }

    func testClipStopsAtTheClipLengthCap() async throws {
        let sim = try await makeSim()
        try await sim.send(.startVideo(seconds: 120))           // the setting is 30 s
        async let clip = nextEvent(sim) { if case .video = $0 { return true }; return false }
        await sim.advance(seconds: 31)
        guard case .video(let recorded)? = await clip else { return XCTFail("no clip reported") }
        XCTAssertEqual(recorded.seconds, 30, accuracy: 0.01)
        XCTAssertNil(recorded.stopReason, "reaching the cap is a normal end")
        XCTAssertEqual(sim.hw.videoCount, 1)
    }

    func testTouchDefaultsActOnTheGlasses() async throws {
        let sim = try await makeSim()
        var keys: [MetaMediaCommand] = []
        sim.mediaKeys = { keys.append($0) }
        let before = sim.hw.volume
        await sim.touch(.swipeForward)
        XCTAssertEqual(sim.hw.volume, before + 10)
        await sim.touch(.tap)
        XCTAssertTrue(sim.hw.musicPlaying)
        await sim.touch(.doubleTap)
        XCTAssertEqual(keys, [.playPause, .next])
        XCTAssertEqual(sim.track, 2, "the simulated music moves on — nothing leaves the sim")
        await sim.touch(.tripleTap)
        XCTAssertEqual(sim.track, 1)
        keys.removeAll()
        sim.mediaKeys = nil                              // the hub sets none: no phone media / Shortcuts
        await sim.touch(.doubleTap)
        XCTAssertEqual(sim.track, 2)
        XCTAssertTrue(keys.isEmpty)
        await sim.setFolded(true)
        let track = sim.track
        await sim.touch(.doubleTap)
        XCTAssertEqual(sim.track, track, "folded glasses ignore the touchpad")
    }

    func testWakeNeedsTheGlassesOn() async throws {
        let sim = try await makeSim()
        await sim.setWorn(false)
        sim.wake()
        XCTAssertEqual(sim.feed.entries.first?.outcome, .refused("The glasses aren't being worn"))
    }

    func testOutOfRangeDropsTheLinkAndComesBack() async throws {
        let sim = try await makeSim()
        await sim.setInRange(false)
        XCTAssertEqual(sim.linkState, .disconnected)
        let why = await refusal { try await sim.send(.speak(text: "hi")) }
        XCTAssertEqual(why, "The glasses are out of range")
        await sim.setInRange(true)
        XCTAssertEqual(sim.linkState, .ready)
    }

    func testFocusFollowsWhatTheGlassesAreDoing() async throws {
        let sim = try await makeSim()
        XCTAssertNil(sim.focus)
        sim.wake()
        XCTAssertEqual(sim.focus, MetaGlassesFocus(part: .mic, pulse: .listening))
        try await sim.send(.setSpeaking(true))
        XCTAssertEqual(sim.focus, MetaGlassesFocus(part: .speakers, pulse: .speaking))
        try await sim.send(.setSpeaking(false))
        try await sim.send(.closeAssistant)
        XCTAssertNil(sim.focus)
        try await sim.send(.startVideo(seconds: 30))
        XCTAssertEqual(sim.focus, MetaGlassesFocus(part: .camera, pulse: .recording))
        await sim.touch(.swipeForward)
        XCTAssertEqual(sim.focus?.part, .touchpad, "a moment's mark shows over the recording")
        try await sim.send(.stopVideo)
        XCTAssertNil(sim.focus, "settles to idle once nothing is going on")
        try await sim.send(.capturePhoto(question: nil))
        XCTAssertEqual(sim.focus, MetaGlassesFocus(part: .camera, pulse: .capture))
    }

    func testImportSavesToPhotosAndReportsTestSceneClips() async throws {
        let sim = try await makeSim()
        var saved: [MetaStoredMedia.Kind] = []
        sim.saveToPhotos = { item in
            guard item.fileURL != nil else { throw MetaGlassesError.refused("a test-scene clip has no video file to save") }
            saved.append(item.kind)
        }
        try await sim.send(.capturePhoto(question: nil))
        try await sim.send(.startVideo(seconds: 5))
        await sim.advance(seconds: 6)                      // test-scene clip: no movie file
        await sim.importAll()
        XCTAssertEqual(saved, [.photo])
        XCTAssertEqual(sim.imported.filter(\.savedToPhotos).count, 1)
        XCTAssertEqual(sim.feed.entries.first?.detail, "1 of 2 saved to Photos · a test-scene clip has no video file to save")
    }

    func testImportMovesMediaToThePhoneAndFreesStorage() async throws {
        let sim = try await makeSim()
        try await sim.send(.capturePhoto(question: nil))
        try await sim.send(.capturePhoto(question: nil))
        XCTAssertEqual(sim.hw.photoCount, 2)
        await sim.importAll()
        XCTAssertTrue(sim.storage.isEmpty)
        XCTAssertEqual(sim.imported.count, 2)
        XCTAssertEqual(sim.hw.storageUsed, 0)
        XCTAssertFalse(sim.phoneOnGlassesWiFi)
    }
}

/// Hold to talk: whatever rate the phone recorded at, the glasses path gets 16 kHz mono PCM16.
final class MetaSimMicConversionTests: XCTestCase {
    func testRecordingAt44kConvertsTo16kPCM() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 44_100.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
            buffer.frameLength = 44_100                                    // one second of a 440 Hz tone
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0 ..< 44_100 { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.3 }
            try file.write(from: buffer)
        }
        let pcm = try XCTUnwrap(MetaSimMic.pcm16k(from: url))
        XCTAssertEqual(Double(pcm.count), 32_000, accuracy: 1_600, "≈ one second of 16 kHz mono Int16")
        XCTAssertEqual(pcm.count % 2, 0)
    }
}

/// "Hey Jarvis": the forgiving phrase match and the glasses' enrolment rules.
@MainActor
final class MetaWakeWordTests: XCTestCase {
    func testWakeEndFindsThePhraseHoweverItIsSpelled() {
        let segs: [(text: String, end: TimeInterval)] = [("Hey", 0.4), ("Jarvis", 0.9), ("what", 1.2), ("time", 1.5)]
        XCTAssertEqual(MetaSimWakeListener.wakeEnd(in: segs), 0.9)
        XCTAssertEqual(MetaSimWakeListener.wakeEnd(in: [("a", 0.3), ("Jervis,", 0.8), ("hi", 1.0)]), 0.8)
        XCTAssertNil(MetaSimWakeListener.wakeEnd(in: [("Jarvis", 0.5)]), "the greeting is part of the phrase")
        XCTAssertNil(MetaSimWakeListener.wakeEnd(in: [("hey", 0.3), ("there", 0.6)]))
        XCTAssertNil(MetaSimWakeListener.wakeEnd(in: [("hey", 0.3), ("jar", 0.6)]), "too short to be the name")
    }

    func testWakeAnnouncesWithTheListeningChime() {
        final class FakeEarcon: EarconPlaying {
            var played: [VoiceEarcon] = []
            func play(_ earcon: VoiceEarcon) -> Int { played.append(earcon); return 0 }
        }
        let listener = MetaSimWakeListener()
        let chime = FakeEarcon()
        listener.earcon = chime
        var heard = false
        listener.onHeard = { heard = true }
        listener.announceWake()
        XCTAssertEqual(chime.played, [.listening], "his chosen Jarvis listening chime, not a new tone")
        XCTAssertTrue(heard)
    }

    func testEnrolmentNeedsThreeSamplesAndTheGlassesOn() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        try await sim.connect()
        let sample = Data(count: 16_000 * 2)           // 1 s
        do {
            try await sim.send(.enrolWakeWord(phrase: "Hey Jarvis", samples: [sample, sample]))
            XCTFail("two samples must be refused")
        } catch MetaGlassesError.refused(let why) {
            XCTAssertTrue(why.contains("exactly 3"), why)
        }
        XCTAssertNil(sim.wakePhrase)
        try await sim.send(.enrolWakeWord(phrase: "Hey Jarvis", samples: [sample, sample, sample]))
        XCTAssertEqual(sim.wakePhrase, "Hey Jarvis")
        await sim.setWorn(false)
        do {
            try await sim.send(.enrolWakeWord(phrase: "Hey Jarvis", samples: [sample, sample, sample]))
            XCTFail("enrolment needs the glasses on")
        } catch MetaGlassesError.refused {}
    }
}

/// The glasses' assistant: chime, listen, done chime, then the turn (touch-and-hold, ring, talk tool).
@MainActor
final class MetaGlassesAssistantTests: XCTestCase {
    final class FakeEarcon: EarconPlaying {
        var played: [VoiceEarcon] = []
        func play(_ earcon: VoiceEarcon) -> Int { played.append(earcon); return 0 }
    }
    final class FakeCapture: MetaQuestionCapturing {
        var pcm: Data
        init(_ pcm: Data) { self.pcm = pcm }
        func captureQuestion() async throws -> Data { pcm }
    }

    private func nextWake(_ sim: SimulatedGlassesTransport) async -> Bool {
        let stream = sim.inbound
        let task = Task { () -> Bool in
            for await event in stream { if case .wake = event { return true } }
            return false
        }
        let timer = Task { try? await Task.sleep(for: .seconds(2)); task.cancel() }
        let got = await task.value
        timer.cancel()
        return got
    }

    func testOpenAssistantChimesListensChimesThenStartsTheTurn() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        try await sim.connect()
        let chime = FakeEarcon()
        sim.earcon = chime
        sim.questionCapture = FakeCapture(Data(count: 32_000))
        async let woke = nextWake(sim)
        try await sim.openAssistant(source: .touch)
        let didWake = await woke
        XCTAssertTrue(didWake, "the question goes to Jarvis")
        XCTAssertEqual(chime.played, [.listening, .thinking], "listening chime, then his done chime")
        XCTAssertFalse(sim.capturingQuestion)
    }

    func testNoQuestionClosesTheAssistantWithoutATurn() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        try await sim.connect()
        let chime = FakeEarcon()
        sim.earcon = chime
        sim.questionCapture = FakeCapture(Data())
        try await sim.openAssistant(source: .touch)
        XCTAssertEqual(chime.played, [.listening, .thinking])
        XCTAssertEqual(sim.feed.entries.first?.detail, "Didn't hear a question")
        XCTAssertNil(sim.focus)
    }

    func testTalkToolOpensTheAssistantAndRespectsTheGlassesState() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        let device = MetaGlassesDevice(transport: sim, voice: FakeVoiceTurnController(), feed: sim.feed,
                                       defaults: UserDefaults(suiteName: "talk-\(UUID().uuidString)")!)
        try await device.session.start()
        XCTAssertTrue(device.capabilities.contains { $0.name == "meta_glasses_talk" })
        let result = try await device.invoke("meta_glasses_talk", args: [:])
        XCTAssertEqual(result["listening"] as? Bool, true)
        XCTAssertTrue(sim.sentFrames.contains(.openAssistant))
        await sim.setFolded(true)
        do {
            _ = try await device.invoke("meta_glasses_talk", args: [:])
            XCTFail("folded glasses can't open the assistant")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("folded"), error.localizedDescription)
        }
    }

    func testRingPickerShowsMetaGlassesLikeTheINMO() {
        XCTAssertEqual(ActionPickerIndex.label(MetaGlassesDevice.model).0, "Meta glasses")
        XCTAssertEqual(ActionPickerIndex.label(MetaGlassesDevice.model).1, "eyeglasses")
        XCTAssertEqual(ActionPickerIndex.title(of: "meta_glasses_talk"), "Talk")
        XCTAssertEqual(ActionPickerIndex.title(of: "meta_glasses_photo"), "Photo")
        XCTAssertEqual(ActionPickerIndex.title(of: "glasses_remote_key"), "Remote key", "INMO titles unchanged")
    }
}

/// Jarvis's tools over the simulated glasses.
@MainActor
final class MetaGlassesDeviceToolTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "meta-tools-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeDevice() async throws -> (MetaGlassesDevice, SimulatedGlassesTransport) {
        let sim = SimulatedGlassesTransport(autoTick: false)
        let device = MetaGlassesDevice(transport: sim, voice: FakeVoiceTurnController(), feed: sim.feed,
                                       defaults: isolatedDefaults())
        try await device.session.start()
        return (device, sim)
    }

    func testCatalogueIsFixedAcrossLinkStates() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        let device = MetaGlassesDevice(transport: sim, voice: FakeVoiceTurnController(), feed: sim.feed,
                                       defaults: isolatedDefaults())
        let before = device.capabilities.map(\.name)
        XCTAssertEqual(before, MetaGlassesDevice.capabilityNames)
        try await device.session.start()
        await sim.setInRange(false)
        XCTAssertEqual(device.capabilities.map(\.name), before, "never add/remove tools on link state")
    }

    func testPhotoToolGivesVisionACopyAndRefusesLikeTheGlasses() async throws {
        let (device, sim) = try await makeDevice()
        let result = try await device.invoke("meta_glasses_photo", args: ["question": "what am I looking at", "confirm": true])
        XCTAssertEqual(result["mime"] as? String, "image/jpeg")
        XCTAssertEqual(result["full_resolution"] as? String, "3024x4032")
        XCTAssertNotNil(Data(base64Encoded: result["base64"] as? String ?? ""))

        await sim.setLEDCovered(true)
        do {
            _ = try await device.invoke("meta_glasses_photo", args: ["confirm": true])
            XCTFail("a covered LED must block the camera")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("capture LED is covered"), error.localizedDescription)
        }
    }

    func testVideoToolIsCappedByTheClipLength() async throws {
        let (device, sim) = try await makeDevice()
        let call = Task { try await device.invoke("meta_glasses_video", args: ["seconds": 120, "confirm": true]) }
        try await Task.sleep(for: .milliseconds(50))
        await sim.advance(seconds: 31)
        let result = try await call.value
        XCTAssertEqual(result["seconds"] as? Int, 30)
        XCTAssertNotNil(result["note"], "says the clip was capped by the glasses' setting")
    }

    func testLookReturnsTheLiveFrameWhileStreaming() async throws {
        let (device, _) = try await makeDevice()
        _ = try await device.invoke("meta_glasses_live", args: ["action": "start"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while device.session.latestLiveFrame == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let look = try await device.invoke("meta_glasses_look", args: [:])
        XCTAssertEqual(look["mime"] as? String, "image/jpeg")
        XCTAssertNotNil(look["base64"])
        _ = try await device.invoke("meta_glasses_live", args: ["action": "stop"])
    }

    func testStatusReportsHardware() async throws {
        let (device, sim) = try await makeDevice()
        await sim.overrideBattery(42)
        let status = try await device.invoke("meta_glasses_status", args: [:])
        XCTAssertEqual(status["battery_percent"] as? Int, 42)
        XCTAssertEqual(status["simulated"] as? Bool, true)
        XCTAssertEqual(status["clip_length_seconds"] as? Int, 30)
    }

    func testSpeakAndVolumeRespectFolding() async throws {
        let (device, sim) = try await makeDevice()
        _ = try await device.invoke("meta_glasses_volume", args: ["level": 80])
        XCTAssertEqual(sim.hw.volume, 80)
        await sim.setFolded(true)
        do {
            _ = try await device.invoke("meta_glasses_speak", args: ["text": "hello"])
            XCTFail("folded glasses can't speak")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("folded"), error.localizedDescription)
        }
    }

    func testHoldGestureStartsAJarvisTurnOnTheSimulator() async throws {
        let sim = SimulatedGlassesTransport(autoTick: false)
        let voice = FakeVoiceTurnController()
        let device = MetaGlassesDevice(transport: sim, voice: voice, feed: sim.feed, defaults: isolatedDefaults())
        try await device.session.start()
        await sim.touch(.hold)
        for _ in 0 ..< 20 where !device.session.turnActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(device.session.turnActive)
        XCTAssertEqual(voice.beginTurnCalls, 1)
    }
}
