import Foundation

/// Everything the ring reports about its own configuration. Nil = not read yet / unsupported.
struct RingSettings: Codable, Equatable {
    var heartRate: RingHeartRateMonitor?
    var spo2: RingSpO2Monitor?
    var stress: RingStressMonitor?
    var hrv: RingHRVMonitor?
    var temperature: RingTemperatureMonitor?
    var touch: RingTouchSettings?
    var gesture: RingTouchSettings?
    var dnd: RingDND?
    var temperatureUnit: RingTemperatureUnit?
    var goals: RingGoals?
    var profile: RingProfile?
    var wearHand: RingWearHand?
    var sedentary: RingSedentary?
}

struct RingMeasurementState: Codable, Equatable {
    enum Phase: String, Codable {
        case measuring, done
        case notWorn = "not_worn"
        case failed, cancelled
        case timedOut = "timed_out"
    }

    var type: RingMeasurementType
    var startedAt: Date
    var phase: Phase
    var value: Int?
    var systolic: Int?
    var diastolic: Int?
    var celsius: Double?
    var finishedAt: Date?
    var detail: String?

    var isActive: Bool { phase == .measuring }
}

struct RingCalibrationState: Equatable {
    enum Phase: Equatable {
        case running, succeeded, cancelled
        case failed(String)
    }

    var phase: Phase
    var results: [Int: Int] = [:]
}

/// A value the ring pushed on its own, stamped when it arrived.
struct RingLiveReading: Codable, Equatable {
    var value: Double
    var date: Date
}

/// One connected ring's protocol state: setup, settings, measurements, pushed events.
///
/// Link-agnostic — `RingManager` owns the Bluetooth side and attaches itself as the link —
/// so all of this is exercised in tests against a fake link.
@MainActor
final class RingSession: ObservableObject {
    @Published private(set) var capabilities = RingCapabilities()
    @Published private(set) var battery: RingBattery?
    @Published private(set) var firmware: String?
    @Published private(set) var hardware: String?
    @Published private(set) var settings = RingSettings() {
        // A change made from the app or by Jarvis survives a relaunch while the ring is away.
        didSet { if settings != oldValue { persistCache() } }
    }
    @Published private(set) var liveActivity: RingActivity?
    @Published private(set) var liveHeartRate: RingLiveReading?
    @Published private(set) var liveSpO2: RingLiveReading?
    @Published private(set) var liveTemperature: RingLiveReading?
    /// `value` is the key code: 1 swipe down, 2 swipe up, 3 click, 4 long press.
    @Published private(set) var lastTouchKey: RingLiveReading?
    /// The last tap or swipe, whichever channel it arrived on.
    @Published private(set) var lastInput: RingInputEvent?
    /// What the ring's taps and swipes are currently set to drive, as read back from the ring.
    @Published private(set) var inputMode: RingInputMode = .off
    @Published private(set) var measurement: RingMeasurementState?
    @Published private(set) var calibration: RingCalibrationState?
    /// Every command and input, decoded. Its own object, so a busy link redraws the log
    /// and not every ring screen.
    let log = RingLog()
    @Published private(set) var chunkSize = RingProtocol.minimumChunk
    @Published private(set) var findPhoneActive = false
    /// Raw optical-sensor samples while a reading runs, newest last (byte values; the
    /// packing isn't documented, so Diagnostics shows them as they arrive).
    @Published private(set) var livePPG: [Int] = []
    @Published private(set) var setupCompletedAt: Date?
    /// What the ring answered when asked, which beats its own feature flags.
    @Published private(set) var probe = RingProbe()
    @Published private(set) var isProbing = false

    let transport: RingTransport

    var onDataUpdated: ((RingMetric) -> Void)?
    var onLiveReading: ((RingMetric, RingLiveReading) -> Void)?
    var onLiveActivity: ((RingActivity) -> Void)?
    var onMeasurementFinished: ((RingMeasurementState) -> Void)?
    var onFindPhone: ((Bool) -> Void)?
    /// A tap, swipe or press on the ring, for whatever the user set it to run.
    var onInput: ((RingInput) -> Void)?
    /// Whether the phone is in use, for the ring's sleep-detection query (`0x73`/62).
    var appIsActive: () -> Bool = { true }

    /// How long an on-demand measurement may run before it is stopped.
    var measurementLimit: TimeInterval = 60

    private var measurementTimer: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var calibrationTimer: Task<Void, Never>?
    private var stillTimeCounter = 0
    private var cacheOwner: (deviceID: String, defaults: UserDefaults)?

    init(transport: RingTransport? = nil) {
        let transport = transport ?? RingTransport()
        self.transport = transport
        transport.onUnsolicited = { [weak self] inbound in self?.handleUnsolicited(inbound) }
        transport.onFrame = { [log] frame in log.record(frame) }
    }

    func attach(_ link: RingLink) {
        transport.link = link
    }

    func setCapabilities(_ capabilities: RingCapabilities) {
        self.capabilities = capabilities
    }

    func setRevision(firmware: String?, hardware: String?) {
        if let firmware { self.firmware = firmware }
        if let hardware { self.hardware = hardware }
    }

    func linkDropped() {
        transport.linkDropped()
        finishMeasurement(.failed, detail: "ring disconnected", sendStop: false)
        if calibration?.phase == .running { calibration?.phase = .failed("ring disconnected") }
    }

    func noteAppBecameActive() {
        stillTimeCounter = 0
    }

    // MARK: Setup

    /// QRing's per-connection setup: clock (reply = capability block A), capability block B,
    /// battery, then every setting the ring supports.
    func runSetup(now: Date = Date()) async {
        if let reply = try? await transport.perform(.setTime(now.addingTimeInterval(1)), until: .single).first {
            capabilities.blockA = reply.payload
        }
        if let reply = try? await transport.perform(.deviceSupport, until: .single).first {
            capabilities.blockB = reply.payload
        }
        await refreshBattery()
        await refreshSettings()
        setupCompletedAt = Date()
    }

    /// Whether this ring does a metric: what it answered when asked, else what it advertises.
    func supports(_ metric: RingMetric) -> Bool {
        probe.supports(metric) ?? capabilities.supports(metric)
    }

    /// Asks the ring for one of everything and remembers what came back. The flags this
    /// firmware advertises miss features it actually has, so the answer decides.
    func runProbe(force: Bool = false) async {
        guard !isProbing, force || probe.isStale(firmware: firmware) else { return }
        isProbing = true
        defer { isProbing = false }
        var result = RingProbe(firmware: firmware, checkedAt: Date())
        for feature in RingFeature.allCases {
            let frames = try? await transport.perform(feature.request, until: feature.until)
            result.record(feature, works: !(frames ?? []).isEmpty)
        }
        probe = result
        persistCache()
    }

    func refreshBattery() async {
        if let value = await read(.battery, RingDecode.battery) { battery = value }
    }

    func refreshSettings() async {
        let caps = capabilities
        if let v = await read(.readHeartRateMonitor, RingDecode.heartRateMonitor) { settings.heartRate = v }
        if caps.hrv, let v = await read(.readHRVMonitor, RingDecode.hrvMonitor) { settings.hrv = v }
        if caps.bloodOxygen, let v = await read(.readSpO2Monitor, RingDecode.spo2Monitor) { settings.spo2 = v }
        if caps.stress, let v = await read(.readStressMonitor, RingDecode.stressMonitor) { settings.stress = v }
        if caps.gesture, let v = await read(.readGesture, RingDecode.touch, accept: { !$0.isTouch }) { settings.gesture = v }
        if caps.touch, let v = await read(.readTouch, RingDecode.touch, accept: \.isTouch) { settings.touch = v }
        if caps.doNotDisturb, let v = await read(.readDND, RingDecode.dnd) { settings.dnd = v }
        if caps.anyTemperature {
            if let v = await read(.readTemperatureUnit, RingDecode.temperatureUnit) { settings.temperatureUnit = v }
            if let v = await read(.readTemperatureMonitor, RingDecode.temperatureMonitor) { settings.temperature = v }
        }
        if let v = await read(.readGoals, RingDecode.goals) { settings.goals = v }
        if let v = await read(.readProfile, RingDecode.profile) { settings.profile = v }
        if let v = await read(.readWearHand, RingDecode.wearHand) { settings.wearHand = v }
        if caps.sedentary, let v = await read(.readSedentary, RingDecode.sedentary) { settings.sedentary = v }
    }

    /// Waits for the reply that decodes and passes `accept`: a late ack for an earlier write, or
    /// a touch reply arriving during a gesture read, shares the opcode.
    private func read<T>(_ request: RingRequest, _ decode: @escaping ([UInt8]) -> T?,
                         accept: @escaping (T) -> Bool = { _ in true }) async -> T? {
        let wanted: ([UInt8]) -> T? = { payload in decode(payload).flatMap { accept($0) ? $0 : nil } }
        let frames = try? await transport.perform(request, until: .packets { wanted($0.payload) != nil })
        return frames?.lazy.compactMap { wanted($0.payload) }.first
    }

    /// Settings writes. Many are not acknowledged, so a missing reply is not an error — the
    /// re-read that follows every write says what the ring actually holds.
    private func write(_ request: RingRequest) async throws {
        do {
            _ = try await transport.perform(request, until: .single)
        } catch RingError.timeout(_) {
            // Unacknowledged write.
        }
    }

    private func require(_ supported: Bool, _ what: String) throws {
        guard supported || !capabilities.isKnown else { throw RingError.unsupported(what) }
    }

    // MARK: Settings

    func setHeartRateMonitoring(enabled: Bool, intervalMinutes: Int?) async throws {
        var monitor = settings.heartRate ?? RingHeartRateMonitor(enabled: enabled, intervalMinutes: 60, start: 5,
                                                                 lowWarning: 0, highWarning: 0, mainSwitch: 1,
                                                                 maxInterval: 60)
        monitor.enabled = enabled
        if let intervalMinutes { monitor.intervalMinutes = intervalMinutes }
        try await write(.writeHeartRateMonitor(monitor))
        settings.heartRate = await read(.readHeartRateMonitor, RingDecode.heartRateMonitor) ?? monitor
    }

    func setSpO2Monitoring(enabled: Bool) async throws {
        try require(capabilities.bloodOxygen, "automatic SpO₂")
        try await write(.writeSpO2Monitor(enabled: enabled))
        settings.spo2 = await read(.readSpO2Monitor, RingDecode.spo2Monitor)
            ?? RingSpO2Monitor(enabled: enabled, intervalMinutes: settings.spo2?.intervalMinutes ?? 0)
    }

    func setStressMonitoring(enabled: Bool) async throws {
        try require(capabilities.stress, "stress monitoring")
        try await write(.writeStressMonitor(enabled: enabled))
        settings.stress = await read(.readStressMonitor, RingDecode.stressMonitor) ?? RingStressMonitor(enabled: enabled)
    }

    func setHRVMonitoring(enabled: Bool, intervalMinutes: Int?) async throws {
        try require(capabilities.hrv, "HRV monitoring")
        let interval = intervalMinutes ?? settings.hrv?.intervalMinutes ?? 60
        try await write(.writeHRVMonitor(enabled: enabled, intervalMinutes: interval))
        settings.hrv = await read(.readHRVMonitor, RingDecode.hrvMonitor)
            ?? RingHRVMonitor(enabled: enabled, intervalSupported: settings.hrv?.intervalSupported ?? false,
                              intervalMinutes: interval)
    }

    func setTemperatureMonitoring(enabled: Bool, intervalMinutes: Int?) async throws {
        try require(capabilities.anyTemperature, "temperature monitoring")
        var monitor = settings.temperature ?? RingTemperatureMonitor(enabled: enabled, intervalMinutes: 30, start: 5,
                                                                     remindIntervalMinutes: 10, alertFlags: 0,
                                                                     customAlertCelsius: 38.5)
        monitor.enabled = enabled
        if let intervalMinutes { monitor.intervalMinutes = intervalMinutes }
        try await write(.writeTemperatureMonitor(monitor))
        settings.temperature = await read(.readTemperatureMonitor, RingDecode.temperatureMonitor) ?? monitor
    }

    func setTouchMode(_ mode: RingTouchMode) async throws {
        try require(capabilities.touch, "touch control")
        let sleepTime = settings.touch?.sleepTime ?? 0
        try await write(.writeTouch(appType: mode.rawValue, sleepTime: sleepTime))
        settings.touch = await read(.readTouch, RingDecode.touch, accept: \.isTouch)
            ?? RingTouchSettings(isTouch: true, mode: mode.rawValue, sleepTime: sleepTime,
                                 touchSleep: settings.touch?.touchSleep ?? false, strength: 0)
    }

    func setGestureMode(_ mode: RingTouchMode, strength: Int?) async throws {
        try require(capabilities.gesture, "gesture control")
        let value = strength ?? settings.gesture?.strength ?? 1
        try await write(.writeGesture(appType: mode.rawValue, strength: value))
        settings.gesture = await read(.readGesture, RingDecode.touch, accept: { !$0.isTouch })
            ?? RingTouchSettings(isTouch: false, mode: mode.rawValue, sleepTime: 0, touchSleep: false, strength: value)
    }

    func setGoals(_ goals: RingGoals) async throws {
        try await write(.writeGoals(goals))
        settings.goals = await read(.readGoals, RingDecode.goals) ?? goals
    }

    func setProfile(_ profile: RingProfile) async throws {
        try await write(.writeProfile(profile))
        settings.profile = await read(.readProfile, RingDecode.profile) ?? profile
    }

    func setTemperatureUnit(celsius: Bool) async throws {
        try require(capabilities.anyTemperature, "temperature units")
        try await write(.writeTemperatureUnit(celsius: celsius))
        settings.temperatureUnit = await read(.readTemperatureUnit, RingDecode.temperatureUnit)
            ?? RingTemperatureUnit(enabled: true, celsius: celsius)
    }

    func setDND(_ dnd: RingDND) async throws {
        try require(capabilities.doNotDisturb, "do not disturb")
        try await write(.writeDND(dnd))
        settings.dnd = await read(.readDND, RingDecode.dnd) ?? dnd
    }

    func setSedentary(_ sedentary: RingSedentary) async throws {
        try require(capabilities.sedentary, "sedentary reminders")
        try await write(.writeSedentary(sedentary))
        settings.sedentary = await read(.readSedentary, RingDecode.sedentary) ?? sedentary
    }

    /// Puts the ring where it reports taps and swipes to the phone: its music mode, with the
    /// reporting channel on. Jarvis runs the user's own action for each one.
    /// Points the ring's taps and swipes at Jarvis, at music, or nowhere, and reads back what
    /// it actually took. Both controls are written whatever the capability flags claim: this
    /// firmware under-reports, and a ring that ignores one may still honour the other.
    func setInputMode(_ mode: RingInputMode) async {
        guard transport.link?.isLinkReady == true else { return }
        // The reporting channel only matters when the presses should reach this app.
        _ = try? await transport.perform(.inputReporting(mode == .jarvis), until: .single)
        try? await write(.writeTouch(appType: mode.appType, sleepTime: settings.touch?.sleepTime ?? 0))
        try? await write(.writeGesture(appType: mode.appType, strength: settings.gesture?.strength ?? 1))
        if let touch = await read(.readTouch, RingDecode.touch, accept: \.isTouch) { settings.touch = touch }
        if let gesture = await read(.readGesture, RingDecode.touch, accept: { !$0.isTouch }) { settings.gesture = gesture }
        let taken = settings.gesture?.mode ?? settings.touch?.mode ?? 0
        inputMode = RingInputMode.allCases.first { $0.appType == taken } ?? .off
        log.note("Ring gestures → \(inputMode.label)",
                 inputMode == mode ? "the ring took it"
                                   : "asked for \(mode.label); the ring kept mode \(taken)")
    }

    func syncClock() async throws {
        let reply = try await transport.perform(.setTime(Date().addingTimeInterval(1)), until: .single)
        if let payload = reply.first?.payload { capabilities.blockA = payload }
    }

    // MARK: Actions

    func findRing() async throws {
        _ = try await transport.perform(.findRing, until: .none)
    }

    func powerOff() async throws {
        _ = try await transport.perform(.powerOff, until: .none)
    }

    func factoryReset() async throws {
        _ = try await transport.perform(.factoryReset, until: .none)
    }

    /// Raw 16-byte command (checksum added); collects same-opcode replies until the ring is quiet.
    func sendRaw(_ bytes: [UInt8]) async throws -> [RingInbound] {
        guard let cmd = bytes.first else { throw RingError.unsupported("an empty command") }
        return try await transport.perform(.command(cmd, Array(bytes.dropFirst().prefix(RingProtocol.payloadLength))),
                                           until: .idle)
    }

    func sendRawBigData(cmd: UInt8, payload: [UInt8]) async throws -> [RingInbound] {
        try await transport.perform(.bigData(cmd, payload), until: .idle)
    }

    // MARK: Measurements

    /// Starts an on-demand measurement; results arrive as `0x69` notifications and move
    /// `measurement` to its final phase.
    func startMeasurement(_ type: RingMeasurementType) async throws {
        if let running = measurement, running.isActive {
            throw RingError.busy("a \(running.type.label.lowercased()) measurement is running")
        }
        try require(capabilities.supportedMeasurements.contains(type), "\(type.label) measurements")
        measurement = RingMeasurementState(type: type, startedAt: Date(), phase: .measuring)
        do {
            _ = try await transport.perform(.startMeasurement(type), until: .none)
        } catch {
            finishMeasurement(.failed, detail: error.localizedDescription, sendStop: false)
            throw error
        }
        armMeasurementTimers(type)
    }

    func cancelMeasurement() {
        finishMeasurement(.cancelled)
    }

    /// Waits until the current measurement ends or `timeout` passes; returns the latest state.
    func awaitMeasurement(timeout: TimeInterval) async -> RingMeasurementState? {
        let deadline = Date().addingTimeInterval(timeout)
        while measurement?.isActive == true, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return measurement
    }

    private func armMeasurementTimers(_ type: RingMeasurementType) {
        measurementTimer?.cancel()
        let limit = type == .healthCheck ? min(30, measurementLimit) : measurementLimit
        measurementTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.measurementTimedOut()
        }
        keepAliveTask?.cancel()
        guard type == .heartRate else { return }
        // QRing nudges the ring every 20 s while a heart-rate reading runs. Bounded by the
        // measurement itself, so this never outlives it.
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.measurement?.isActive == true else { return }
                _ = try? await self.transport.perform(.heartRateKeepAlive, until: .none)
            }
        }
    }

    private func measurementTimedOut() {
        guard let running = measurement, running.isActive else { return }
        if running.type == .healthCheck, running.value != nil {
            finishMeasurement(.done)
        } else {
            finishMeasurement(.timedOut, detail: "no reading from the ring")
        }
    }

    private func handleMeasurement(_ reading: RingMeasurementReading) {
        guard var running = measurement, running.isActive, reading.type == running.type.rawValue else { return }
        if reading.errorCode == 1 {
            finishMeasurement(.notWorn, detail: "the ring is not being worn")
            return
        }
        if reading.errorCode != 0 {
            finishMeasurement(.failed, detail: "ring error \(reading.errorCode)")
            return
        }
        let hasValue = running.type == .bloodPressure ? reading.systolic > 0 : reading.value > 0
        guard hasValue else { return }
        running.value = reading.value
        if reading.systolic > 0 { running.systolic = reading.systolic }
        if reading.diastolic > 0 { running.diastolic = reading.diastolic }
        if running.type == .temperature { running.celsius = reading.celsius }
        measurement = running
        // A health check keeps streaming values until its window closes.
        if running.type != .healthCheck { finishMeasurement(.done) }
    }

    private func finishMeasurement(_ phase: RingMeasurementState.Phase, detail: String? = nil, sendStop: Bool = true) {
        guard var running = measurement, running.isActive else { return }
        measurementTimer?.cancel()
        keepAliveTask?.cancel()
        running.phase = phase
        running.detail = detail
        running.finishedAt = Date()
        measurement = running
        if sendStop {
            let stop: RingRequest
            switch running.type {
            case .bloodPressure:
                stop = .stopMeasurement(.bloodPressure, value: running.systolic ?? 0, extra: running.diastolic ?? 0)
            case .temperature, .healthCheck:
                stop = .stopMeasurement(running.type)
            default:
                stop = .stopMeasurement(running.type, value: running.value ?? 0)
            }
            Task { [transport] in _ = try? await transport.perform(stop, until: .none) }
        }
        onMeasurementFinished?(running)
    }

    // MARK: Wearing calibration

    func startCalibration() async throws {
        try require(capabilities.wearingCalibration, "wearing calibration")
        calibration = RingCalibrationState(phase: .running)
        _ = try await transport.perform(.calibration(mode: 6), until: .none)
        calibrationTimer?.cancel()
        calibrationTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.calibration?.phase == .running else { return }
            self.calibration?.phase = .failed("timed out")
        }
    }

    func cancelCalibration() async {
        calibrationTimer?.cancel()
        if calibration?.phase == .running { calibration?.phase = .cancelled }
        _ = try? await transport.perform(.calibration(mode: 2), until: .none)
    }

    private func handleCalibration(_ reply: (dataType: Int, result: Int)) {
        guard var state = calibration, state.phase == .running else { return }
        state.results[reply.dataType] = reply.result
        if state.results[1] == 1, state.results[2] == 1 {
            state.phase = .succeeded
            calibrationTimer?.cancel()
        }
        calibration = state
    }

    // MARK: Notifications

    func handleUnsolicited(_ inbound: RingInbound) {
        guard inbound.channel == .command else { return }
        switch inbound.cmd {
        case RingOp.deviceEvent:
            handle(RingDecode.deviceEvent(inbound.payload))
        case RingOp.measure:
            if let reading = RingDecode.measurement(inbound.payload) { handleMeasurement(reading) }
        case RingOp.calibration:
            handleCalibration(RingDecode.calibration(inbound.payload))
        case RingOp.packageLength:
            chunkSize = max(RingProtocol.minimumChunk, Int(inbound.payload.first ?? 0))
        case RingOp.findPhone:
            let active = inbound.payload.first == 1
            findPhoneActive = active
            onFindPhone?(active)
        case RingOp.camera:
            // In camera mode the shutter press comes to the app instead of to iOS.
            noteInput(.tap)
        case RingOp.ppgData:
            livePPG = (livePPG + inbound.payload.map(Int.init)).suffix(180)
        case RingOp.musicCommand:
            // In the ring's music mode every tap and swipe arrives as one of these.
            if let input = RingInput(musicAction: Int(inbound.payload.first ?? 0)) { noteInput(input) }
        default:
            break
        }
    }

    private func noteInput(_ input: RingInput) {
        lastInput = RingInputEvent(input: input, date: Date())
        onInput?(input)
    }

    private func handle(_ event: RingDeviceEvent) {
        switch event {
        case .dataUpdated(let metric):
            onDataUpdated?(metric)
        case .battery(let value):
            battery = value
            if value.charging, calibration?.phase == .running {
                calibration?.phase = .failed("charging — calibration needs the ring off the charger")
            }
        case .goalsChanged:
            Task { [weak self] in
                guard let self else { return }
                if let goals = await self.read(.readGoals, RingDecode.goals) { self.settings.goals = goals }
            }
        case .wearHand(let flag):
            settings.wearHand?.left = flag == 1
        case .liveActivity(let activity):
            liveActivity = activity
            onLiveActivity?(activity)
        case .settingsChanged:
            Task { [weak self] in await self?.refreshSettings() }
        case .touchSleep(let on):
            settings.touch?.touchSleep = on
        case .touchKey(let key):
            lastTouchKey = RingLiveReading(value: Double(key), date: Date())
            if let input = RingInput(touchKey: key) { noteInput(input) }
        case .press(let input):
            noteInput(input)
        case .instantHeartRate(let bpm):
            guard bpm > 0 else { return }
            let reading = RingLiveReading(value: Double(bpm), date: Date())
            liveHeartRate = reading
            onLiveReading?(.heartRate, reading)
        case .instantSpO2(let percent):
            guard percent > 0 else { return }
            let reading = RingLiveReading(value: Double(percent), date: Date())
            liveSpO2 = reading
            onLiveReading?(.spo2, reading)
        case .liveTemperature(let celsius):
            guard celsius > 0 else { return }
            let reading = RingLiveReading(value: celsius, date: Date())
            liveTemperature = reading
            onLiveReading?(.temperature, reading)
        case .phoneStillTimeRequest:
            let counter = stillTimeCounter
            stillTimeCounter += 1
            let request = RingRequest.phoneStillTime(inUse: appIsActive(), counter: counter)
            Task { [transport] in _ = try? await transport.perform(request, until: .none) }
        case .other:
            break
        }
    }

    // MARK: Cache

    private struct Cache: Codable {
        var capabilities: RingCapabilities
        var settings: RingSettings
        var firmware: String?
        var hardware: String?
        var battery: RingBattery?
        var probe: RingProbe?
    }

    private static func cacheKey(_ deviceID: String) -> String { "jc.ring.cache.\(deviceID)" }

    /// Restores what the ring last reported, so screens and skills stay gated while it's away.
    func loadCache(deviceID: String, defaults: UserDefaults = .standard) {
        // Only after restoring: saving midway would drop the fields not restored yet.
        defer { cacheOwner = (deviceID, defaults) }
        guard let data = defaults.data(forKey: Self.cacheKey(deviceID)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        if !capabilities.isKnown { capabilities = cache.capabilities }
        if settings == RingSettings() { settings = cache.settings }
        firmware = firmware ?? cache.firmware
        hardware = hardware ?? cache.hardware
        battery = battery ?? cache.battery
        if probe.isEmpty, let cached = cache.probe { probe = cached }
    }

    func saveCache(deviceID: String, defaults: UserDefaults = .standard) {
        let cache = Cache(capabilities: capabilities, settings: settings, firmware: firmware,
                          hardware: hardware, battery: battery, probe: probe)
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey(deviceID)) }
        cacheOwner = (deviceID, defaults)
    }

    private func persistCache() {
        guard let cacheOwner else { return }
        saveCache(deviceID: cacheOwner.deviceID, defaults: cacheOwner.defaults)
    }
}
