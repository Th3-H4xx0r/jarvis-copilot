import XCTest
@testable import JarvisCopilot

/// Every wearable says what its commands are doing now, from what its own screen shows — and
/// says nothing when it can't tell.
@MainActor
final class CommandLiveStateTests: XCTestCase {

    // MARK: Bottle

    private func bottleStatus(reminders: Bool = false, screen: UInt8 = 10, sterilising: Bool = false,
                              autoClean: Bool = false, touchLock: Bool = false, dailyReset: Bool = false,
                              strong: Bool = false) -> BottleStatus? {
        var frame = [UInt8](repeating: 0, count: 18)
        frame[0] = 0x07
        frame[1] = reminders ? 0b10 : 0
        frame[4] = screen
        frame[5] = sterilising ? 1 : 0
        frame[6] = 40
        frame[7] = autoClean ? 1 : 0
        frame[8] = touchLock ? 1 : 0
        frame[10] = dailyReset ? 1 : 0
        frame[11] = strong ? 1 : 0
        return BottleStatus(frame: Data(frame))
    }

    func testTheBottleReportsItsSwitchesAndSettings() throws {
        let on = try XCTUnwrap(bottleStatus(reminders: true, screen: 12, sterilising: true, autoClean: true,
                                            touchLock: true, dailyReset: true, strong: true))
        for skill in ["bottle_sterilise", "bottle_auto_clean", "bottle_touch_lock", "bottle_reminders", "bottle_daily_reset"] {
            XCTAssertEqual(VsitooS1Pro.commandState(skill, status: on), CommandLiveState(on: true), skill)
        }
        XCTAssertEqual(VsitooS1Pro.commandState("bottle_set_uv_intensity", status: on)?.mode, "strong")
        XCTAssertEqual(VsitooS1Pro.commandState("bottle_set_screen_seconds", status: on)?.mode, "12")

        let off = try XCTUnwrap(bottleStatus())
        XCTAssertEqual(VsitooS1Pro.commandState("bottle_sterilise", status: off), CommandLiveState(on: false))
        XCTAssertEqual(VsitooS1Pro.commandState("bottle_set_uv_intensity", status: off)?.mode, "normal")
        XCTAssertNil(VsitooS1Pro.commandState("bottle_sterilise", status: on)?.endsAt, "the bottle doesn't say how long a cycle runs")
        XCTAssertNil(VsitooS1Pro.commandState("bottle_sync_clock", status: on))
    }

    // MARK: ESP32

    func testTheBoardReportsItsLedPinsRelayAndScript() {
        let pins: [UInt8: Esp32Protocol.PinState] = [
            2: .init(gpio: 2, mode: .output, value: 1),
            4: .init(gpio: 4, mode: .pwm, value: 128),
            5: .init(gpio: 5, mode: .input, value: 1),
        ]
        func state(_ skill: String, _ args: [String: String] = [:], led: UInt8? = 2,
                   relay: Esp32Protocol.RelayStatus? = nil, script: Esp32Protocol.ScriptStatus? = nil) -> CommandLiveState? {
            Esp32Board.commandState(skill, arguments: args, ledGPIO: led, pins: pins, relay: relay, script: script)
        }
        XCTAssertEqual(state("esp32_set_led"), CommandLiveState(on: true))
        XCTAssertNil(state("esp32_set_led", led: nil), "no pin list yet: can't tell")
        XCTAssertEqual(state("esp32_write_pin", ["gpio": "2"]), CommandLiveState(on: true))
        XCTAssertNil(state("esp32_write_pin", ["gpio": "5"]), "an input isn't driven")
        XCTAssertNil(state("esp32_write_pin"), "which pin?")
        XCTAssertEqual(state("esp32_set_pin_mode", ["gpio": "5"])?.mode, "input")
        XCTAssertEqual(state("esp32_set_pwm", ["gpio": "4"])?.mode, "128")
        XCTAssertNil(state("esp32_notification_relay"), "older firmware never answers")
        XCTAssertEqual(state("esp32_notification_relay", relay: .init(on: true, state: .waiting, forwarded: 0)),
                       CommandLiveState(on: true))
        let running = Esp32Protocol.ScriptStatus(state: .running, autostart: true, size: 10, name: "door", error: "")
        XCTAssertEqual(state("esp32_script_control", script: running), CommandLiveState(on: true))
        let none = Esp32Protocol.ScriptStatus(state: .none, autostart: false, size: 0, name: "", error: "")
        XCTAssertNil(state("esp32_script_control", script: none))
    }

    // MARK: Keep Alive

    func testKeepAliveFollowsTheWearableItNames() {
        let defaults = isolatedDefaults()
        WearableKeepAlive.set(true, for: WearableKeepAlive.ring, defaults: defaults)
        XCTAssertEqual(WearablesDevice.keepAliveState(["wearable": "ring", "state": "toggle"], defaults: defaults),
                       CommandLiveState(on: true, mode: "on"))
        XCTAssertEqual(WearablesDevice.keepAliveState(["wearable": "x5ring"], defaults: defaults),
                       CommandLiveState(on: false, mode: "off"))
        XCTAssertNil(WearablesDevice.keepAliveState([:], defaults: defaults))
        XCTAssertNil(WearablesDevice.keepAliveState(["wearable": "glasses"], defaults: defaults), "no switch")
        XCTAssertNil(WearablesDevice().commandState("wearables_keep_alive"), "needs the wearable")
    }

    // MARK: Dashcam

    func testTheDashcamReportsRecordingAndItsSwitches() async {
        let defaults = isolatedDefaults()
        let server = FakeSyncServer()
        server.rules.upload = true
        server.rules.keepOnPhone = false
        let sync = DashcamSync()
        sync.defaults = defaults
        sync.server = server
        sync.onCameraProvider = { false }
        let device = DashcamDevice()
        device.sync = sync
        device.wifi = { false }
        device.setup = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM") }

        XCTAssertNil(device.commandState("dashcam_set_recording"), "never heard from the camera")
        sync.noteRecording(true)
        XCTAssertEqual(device.commandState("dashcam_set_recording"), CommandLiveState(on: true), "last known, as the page shows")

        XCTAssertNil(device.commandState("dashcam_set_options", arguments: ["upload": "true"]), "rules not loaded yet")
        await sync.refreshRules()
        XCTAssertEqual(device.commandState("dashcam_set_options", arguments: ["upload": "false"]), CommandLiveState(on: true))
        XCTAssertEqual(device.commandState("dashcam_set_options", arguments: ["keep_on_phone": "true"]), CommandLiveState(on: false))
        sync.autoSync = false
        XCTAssertEqual(device.commandState("dashcam_set_options", arguments: ["auto_download": "true"]), CommandLiveState(on: false))
        XCTAssertEqual(device.commandState("dashcam_set_options", arguments: ["lock_screen_progress": "true"])?.on,
                       DashcamSyncBeacon.enabled)
        XCTAssertNil(device.commandState("dashcam_set_options"), "which switch?")

        device.setup = { nil }
        XCTAssertNil(device.commandState("dashcam_set_recording"), "no dashcam")
    }

    // MARK: Car lights and the car

    func testTheLightsReportWhatTheyWereLastSet() throws {
        let manager = CarLightsManager(defaults: isolatedDefaults())
        manager.pair(.init(id: UUID(), name: "MELK-OC21", rssi: -50))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lamps-\(UUID().uuidString).json")
        let lights = CarLightsDevice(manager: manager, layouts: CarLightLayoutStore(file: file), defaults: isolatedDefaults())
        XCTAssertNil(lights.commandState("lights_set"), "nothing set yet: no guess")

        manager.apply(.power(false))
        XCTAssertEqual(lights.commandState("lights_set", arguments: ["power": "true"])?.on, false)
        manager.apply(.power(true))
        manager.apply(.color(try XCTUnwrap(MelkColor(text: "blue"))))
        XCTAssertEqual(lights.commandState("lights_set"), CommandLiveState(on: true, mode: "blue"))
        manager.apply(.effect(193))
        XCTAssertEqual(lights.commandState("lights_set", arguments: ["effect": "193"])?.mode, MelkCatalog.effect(id: 193)?.name)
        XCTAssertNil(lights.commandState("lights_set", arguments: ["target": "Dashboard"]), "no such lights")

        let state = CarLightsState()
        XCTAssertEqual(CarLightsDevice.commandState("lights_timer", arguments: ["timer": "off"], state: state),
                       CommandLiveState(on: MelkTimer.defaults(.off).enabled))
        XCTAssertNil(CarLightsDevice.commandState("lights_timer", arguments: [:], state: state))
        XCTAssertEqual(CarLightsDevice.commandState("lights_set", arguments: ["music": "off"], state: state)?.mode, "off")
        XCTAssertEqual(CarLightsDevice.commandState("lights_setup", arguments: ["pin_order": "GRB"], state: state)?.mode, "RGB")
    }

    func testACarControlReportsItsValue() {
        func control(_ kind: WearableControl.Kind) -> WearableControl {
            WearableControl(id: "lights.x", title: "X", symbol: "power", kind: kind) { _ in }
        }
        XCTAssertEqual(CarDevice.state(of: control(.toggle(isOn: true))), CommandLiveState(on: true, mode: "on"))
        XCTAssertEqual(CarDevice.state(of: control(.level(value: 60, range: 0...100, step: 5, unit: "%")))?.mode, "60")
        XCTAssertEqual(CarDevice.state(of: control(.choice(selected: "blue", options: [.init(id: "blue", title: "Blue")])))?.mode, "blue")
        XCTAssertNil(CarDevice.state(of: control(.choice(selected: "", options: [.init(id: "blue", title: "Blue")]))))
        XCTAssertNil(CarDevice.state(of: control(.button)))
    }

    // MARK: Glasses

    func testTheGlassesReportTheirSettingsAndModule() {
        var status = InmoDeviceStatus()
        func state(_ skill: String, _ args: [String: String] = [:], connected: Bool = true) -> CommandLiveState? {
            InmoGo3Device.commandState(skill, arguments: args, status: status, connected: connected)
        }
        XCTAssertNil(state("glasses_set_dnd"), "not reported: unknown")
        status.dnd = true
        status.brightness = 70
        status.volume = 35
        status.screenTimeoutSelector = 1
        status.module = 4
        XCTAssertEqual(state("glasses_set_dnd"), CommandLiveState(on: true))
        XCTAssertEqual(state("glasses_set_brightness")?.mode, "70")
        XCTAssertEqual(state("glasses_set_volume")?.mode, "35")
        XCTAssertEqual(state("glasses_set_screen_timeout")?.mode, "30")
        XCTAssertEqual(state("glasses_open_module")?.mode, "ai")
        XCTAssertEqual(state("glasses_open_module", ["module": "ai"])?.on, true)
        XCTAssertEqual(state("glasses_close_module", ["module": "camera"])?.on, false)
        XCTAssertNil(state("glasses_open_module", connected: false), "nothing is open on glasses that are away")
        XCTAssertEqual(state("glasses_set_dnd", connected: false), CommandLiveState(on: true), "last reported, as the page shows")
    }

    func testTheGlassesScreenFeaturesAndNavigationReportTheirOwnState() {
        let device = InmoGo3Device(identity: "inmo-go3-fixture", defaults: isolatedDefaults())
        let screens = ScreenStates()
        device.screenControls = screens
        screens.states = ["glasses_notes": CommandLiveState(on: true)]
        XCTAssertEqual(device.commandState("glasses_notes"), CommandLiveState(on: true))
        XCTAssertNil(device.commandState("glasses_translate"))
        XCTAssertNil(device.commandState("glasses_navigate"), "no navigator installed")
        device.featureStates["glasses_navigate"] = { CommandLiveState(on: true) }
        XCTAssertEqual(device.commandState("glasses_navigate"), CommandLiveState(on: true))
    }

    func testTheRealScreensReportCaptionsAndGlassesAI() {
        let bridge = LiveLensBridge(source: { IdleCaptions() }, defaults: isolatedDefaults(), glassesReady: { false })
        let controls = LiveGlassesScreenControls(captions: { bridge })
        bridge.enabled = false
        XCTAssertEqual(controls.state("glasses_captions"), CommandLiveState(on: false))
        bridge.enabled = true
        XCTAssertEqual(controls.state("glasses_captions"), CommandLiveState(on: true))
        XCTAssertNil(controls.state("glasses_talk"), "Talk has no on/off")
    }

    // MARK: Rings and band

    func testTheR12ReportsItsSettings() {
        var settings = RingSettings()
        XCTAssertNil(ColmiR12.commandState("ring_set_monitoring", arguments: ["metric": "heart_rate"], settings: settings))
        settings.heartRate = RingHeartRateMonitor(enabled: true, intervalMinutes: 5, start: 0, lowWarning: 0, highWarning: 0,
                                                  mainSwitch: 1, maxInterval: 60)
        settings.stress = RingStressMonitor(enabled: false)
        settings.gesture = RingTouchSettings(isTouch: false, mode: RingTouchMode.music.rawValue, sleepTime: 0, touchSleep: false, strength: 5)
        settings.temperatureUnit = RingTemperatureUnit(enabled: true, celsius: false)
        XCTAssertEqual(ColmiR12.commandState("ring_set_monitoring", arguments: ["metric": "heart_rate"], settings: settings),
                       CommandLiveState(on: true))
        XCTAssertEqual(ColmiR12.commandState("ring_set_monitoring", arguments: ["metric": "stress"], settings: settings),
                       CommandLiveState(on: false))
        XCTAssertNil(ColmiR12.commandState("ring_set_monitoring", arguments: [:], settings: settings), "which metric?")
        XCTAssertEqual(ColmiR12.commandState("ring_set_touch_mode", arguments: ["control": "gesture"], settings: settings)?.mode, "music")
        XCTAssertNil(ColmiR12.commandState("ring_set_touch_mode", arguments: ["control": "touch"], settings: settings))
        XCTAssertEqual(ColmiR12.commandState("ring_set_preferences", arguments: ["temperature_unit": "celsius"], settings: settings)?.mode,
                       "fahrenheit")
    }

    func testTheR12ReportsItsGestureModeAndReadings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CommandLiveState-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = FakeRingBackend(directory: directory)
        let ring = ColmiR12(backend: backend)
        XCTAssertNil(ring.commandState("ring_set_input_mode"), "no inputs before the ring's id is known")
        let inputs = RingInputStore(deviceID: "ring-test", defaults: isolatedDefaults())
        inputs.setMode(.music)
        backend.inputs = inputs
        XCTAssertEqual(ring.commandState("ring_set_input_mode"), CommandLiveState(mode: "music"))
        XCTAssertEqual(ring.commandState("ring_measure"), CommandLiveState(on: false), "nothing measuring")
        XCTAssertNil(ring.commandState("ring_workout"), "this backend runs no workouts")

        XCTAssertEqual(ColmiR12.measuring("spo2", asked: nil), CommandLiveState(on: true, mode: "spo2"))
        XCTAssertEqual(ColmiR12.measuring("spo2", asked: "heart_rate"), CommandLiveState(on: false, mode: "spo2"))
    }

    func testTheX5ReportsAReadingWithItsEndAndItsMonitoring() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = X5Measurement(type: .heartRate, startedAt: start, seconds: 30, isActive: true)
        XCTAssertEqual(X5Ring.measureState(reading, asked: "heart_rate"),
                       CommandLiveState(on: true, mode: "heart_rate", endsAt: start.addingTimeInterval(30)))
        XCTAssertEqual(X5Ring.measureState(reading, asked: "spo2"), CommandLiveState(on: false, mode: "heart_rate"))
        var done = reading
        done.isActive = false
        XCTAssertEqual(X5Ring.measureState(done, asked: nil), CommandLiveState(on: false))

        let hrv = X5Monitoring(on: true, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59, weekdays: 0x7F,
                               intervalMinutes: 30, type: .hrv)
        XCTAssertEqual(X5Ring.monitoringState([.hrv: hrv], metric: "hrv"), CommandLiveState(on: true))
        XCTAssertNil(X5Ring.monitoringState([.hrv: hrv], metric: "spo2"), "not read yet")
        XCTAssertNil(X5Ring.monitoringState([.hrv: hrv], metric: nil))
    }

    func testTheBandReportsItsSwitchesReadingAndPlan() {
        var reported = BandDevice.Reported(settings: .e910Default)
        func state(_ skill: String, _ args: [String: String] = [:]) -> CommandLiveState? {
            BandDevice.commandState(skill, arguments: args, reported: reported)
        }
        XCTAssertEqual(state("band_set_monitoring", ["metric": "heart_rate"]), CommandLiveState(on: true))
        XCTAssertEqual(state("band_set_monitoring", ["metric": "hrv"]), CommandLiveState(on: false))
        XCTAssertNil(state("band_set_monitoring", ["metric": "spo2"]), "the overnight SpO2 window wasn't read")
        XCTAssertNil(state("band_set_raise_to_wake"), "not read")
        XCTAssertEqual(state("band_find"), CommandLiveState(on: false))
        XCTAssertEqual(state("band_measure"), CommandLiveState(on: false))

        reported.heartRateAlarm = BandHeartRateAlarm(enabled: true, high: 150, low: 50)
        reported.oxygen = BandOxygenSchedule(enabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
        reported.alerts = BandAlertSwitches(states: ["calls": 1, "sms": 2])
        reported.measuring = .bloodOxygen
        reported.finding = true
        XCTAssertEqual(state("band_set_heart_rate_alarm"), CommandLiveState(on: true))
        XCTAssertEqual(state("band_set_monitoring", ["metric": "spo2"]), CommandLiveState(on: true))
        XCTAssertEqual(state("band_set_alerts", ["calls": "true"]), CommandLiveState(on: true))
        XCTAssertEqual(state("band_set_alerts", ["messages": "true"]), CommandLiveState(on: false))
        XCTAssertEqual(state("band_measure", ["type": "spo2"]), CommandLiveState(on: true, mode: "spo2"))
        XCTAssertEqual(state("band_find"), CommandLiveState(on: true))

        let plan = BandMeasurePlan()
        XCTAssertEqual(BandDevice.planState(plan, arguments: [:])?.mode, plan.control.rawValue)
        XCTAssertEqual(BandDevice.planState(plan, arguments: ["heart_rate": "30"])?.mode, String(plan.interval("heart_rate")))
        XCTAssertEqual(BandDevice.planState(plan, arguments: ["night_start": "21:00"])?.mode,
                       String(format: "%02d:%02d", plan.nightStart / 60, plan.nightStart % 60))
        XCTAssertEqual(BandDevice.unitState(["temperature": "celsius"])?.mode, TemperatureUnit.current.rawValue)
        XCTAssertNil(BandDevice.unitState([:]))
    }

    // MARK: Widget values

    func testEveryCommandValueIsInTheCatalogue() {
        let keys = WidgetDataCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "keys are unique")
        for value in WidgetDataCatalog.commandValues {
            XCTAssertTrue(value.onLabel != nil || value.modeLabel != nil, value.skill)
            if value.onLabel != nil { XCTAssertEqual(WidgetDataCatalog.entry(value.key)?.kind, .bool, value.key) }
            if value.modeLabel != nil { XCTAssertEqual(WidgetDataCatalog.entry(value.modeKey)?.kind, .text, value.modeKey) }
            if value.endsLabel != nil { XCTAssertEqual(WidgetDataCatalog.entry(value.endsKey)?.kind, .number, value.endsKey) }
            XCTAssertTrue(value.key.hasPrefix(value.device + "."), value.key)
        }
        XCTAssertEqual(WidgetDataCatalog.entry("bottle.sterilise")?.label, "Bottle sterilising")
    }

    func testTheHubPublishesWhatEachDeviceReports() {
        let ends = Date(timeIntervalSince1970: 1_800_000_030)
        let bottle = StateDevice(["bottle_sterilise": CommandLiveState(on: true),
                                  "bottle_set_uv_intensity": CommandLiveState(mode: "strong")])
        let x5 = StateDevice(["x5_measure": CommandLiveState(on: true, mode: "spo2", endsAt: ends)])
        let values = WearablesWidgetData.commandValues(["bottle": bottle, "x5ring": x5])
        XCTAssertEqual(values["bottle.sterilise"], .bool(true))
        XCTAssertEqual(values["bottle.set_uv_intensity"], .string("strong"))
        XCTAssertNil(values["bottle.auto_clean"], "the device can't tell: no value")
        XCTAssertEqual(values["x5ring.measure"], .bool(true))
        XCTAssertEqual(values["x5ring.measure_mode"], .string("spo2"))
        XCTAssertEqual(values["x5ring.measure_ends"], .number(ends.timeIntervalSince1970))
    }
}

/// A device that reports fixed states.
@MainActor
private final class StateDevice: WearableDevice {
    static let model = "Test"
    let deviceID = "state-device"
    let isConnected = true
    let capabilities: [DeviceCapability] = []
    let states: [String: CommandLiveState]
    init(_ states: [String: CommandLiveState]) { self.states = states }
    func snapshot() -> [String: Any] { [:] }
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] { [:] }
    func commandState(_ skill: String) -> CommandLiveState? { states[skill] }
}

@MainActor
private final class ScreenStates: GlassesScreenControls {
    var states: [String: CommandLiveState] = [:]
    func note(_ action: String) async throws -> [String: Any] { [:] }
    func translate(on: Bool, from: String?, to: String?) async throws -> [String: Any] { [:] }
    func captions(on: Bool) -> [String: Any] { [:] }
    func talk() async throws -> [String: Any] { [:] }
    func jarvisAI(on: Bool) async -> [String: Any] { [:] }
    func state(_ skill: String) -> CommandLiveState? { states[skill] }
}

@MainActor
private final class IdleCaptions: LiveCaptionSource {
    var isCapturing: Bool { false }
    func captionSnapshot() -> LiveCaptionSnapshot { LiveCaptionSnapshot(partial: "", segments: []) }
    func startCapture() async -> Bool { false }
    func runFactCheck() async -> (title: String, text: String)? { nil }
}
