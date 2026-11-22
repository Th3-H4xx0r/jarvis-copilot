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
        await sim.touch(.doubleTap)
        XCTAssertEqual(keys, [.playPause, .next])
        await sim.setFolded(true)
        await sim.touch(.tap)
        XCTAssertEqual(keys.count, 2, "folded glasses ignore the touchpad")
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
