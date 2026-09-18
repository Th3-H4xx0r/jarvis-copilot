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
    /// When the sensor first read skin: the ring is on the finger. Arrives well
    /// before the first number, so it is what "put the ring on" waits for.
    var skinContactAt: Date?
    /// When the first number arrived; the reading settles for a few seconds after.
    var firstValueAt: Date?

    var isActive: Bool { phase == .measuring }

    /// Whether the reading goes through the optical sensor, which has to be
    /// against skin — everything but temperature.
    var usesOpticalSensor: Bool { type != .temperature }
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
    /// Newest raw accelerometer sample (needs the patched firmware, 3.11.00+).
    @Published private(set) var liveAccelerometer: RingAccelSample?
    /// nil until the first read; false when the ring answered "unsupported" (stock firmware).
    @Published private(set) var accelerometerSupported: Bool?
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
    /// How long a reading stays live after its first number, like a watch
    /// showing the reading move before it settles.
    var measurementSettle: TimeInterval = 10
    /// How long a heart rate runs as a one-shot before it switches to real-time
    /// mode. The one-shot is the wear check — off a finger the ring says "not
    /// worn" within 3–7 s — but it only ever reports one number, repeated. Real-
    /// time mode streams a new bpm every second once the sensor has warmed up.
    var heartRateWearCheck: TimeInterval = 8
    /// Whether the running heart rate has switched to real-time mode, so its
    /// type-6 frames are this reading's values and a real-time stop is owed.
    private var streamingHeartRate = false
    private var liveSwitchTask: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var calibrationTimer: Task<Void, Never>?
    private var stillTimeCounter = 0
    private var cacheOwner: (deviceID: String, defaults: UserDefaults)?

    private let defaults: UserDefaults

    init(transport: RingTransport? = nil, defaults: UserDefaults = .standard) {
        let transport = transport ?? RingTransport()
        self.transport = transport
        self.defaults = defaults
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
        if realtimeStopOwed {
            let answered = await sendRealtimeStop()
            log.note("Ring sensor", answered ? "stopped real-time mode left running on an earlier link"
                                             : "stop still owed; the ring did not answer")
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

    // MARK: Accelerometer

    /// Runs on STOCK firmware. The `0xA1` "wearing calibration" mode makes the ring stream a
    /// telemetry burst once a second; subtype 3 of that burst carries the newest accelerometer
    /// sample from the sensor FIFO (chip-independent). We turn the mode on, wait for one fresh
    /// subtype-3 packet (extracted in `handleUnsolicited`), then turn it off.
    private var accelStreaming = false

    func readAccelerometer() async throws -> RingAccelSample {
        return try await withAccelTelemetry {
            let before = self.liveAccelerometer?.date
            for _ in 0..<40 {                                   // ~4 s, telemetry ticks ~1 Hz
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let a = self.liveAccelerometer, a.date != before {
                    self.accelerometerSupported = true
                    return a
                }
            }
            self.accelerometerSupported = false
            throw RingError.timeout(RingOp.calibration)
        }
    }

    /// `count` samples from the telemetry stream. The ring pushes ~1 per second, so `intervalMs`
    /// only sets the minimum spacing; faster than the ring emits just returns repeats.
    func streamAccelerometer(count: Int, intervalMs: Int) async throws -> [RingAccelSample] {
        return try await withAccelTelemetry {
            var out: [RingAccelSample] = []
            var lastDate = self.liveAccelerometer?.date
            let deadline = Date().addingTimeInterval(Double(max(1, count)) * 1.5 + 5)
            while out.count < max(1, count), Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(max(40, intervalMs)) * 1_000_000)
                if let a = self.liveAccelerometer, a.date != lastDate {
                    out.append(a); lastDate = a.date; self.accelerometerSupported = true
                }
            }
            if out.isEmpty { self.accelerometerSupported = false; throw RingError.timeout(RingOp.calibration) }
            return out
        }
    }

    /// Turns the `0xA1` telemetry stream on for the duration of `body`, then off — without
    /// touching the wearing-calibration UI state.
    private func withAccelTelemetry<T>(_ body: () async throws -> T) async throws -> T {
        accelStreaming = true
        _ = try? await transport.perform(.calibration(mode: 6), until: .none)
        defer {
            accelStreaming = false
            Task { _ = try? await transport.perform(.calibration(mode: 2), until: .none) }
        }
        return try await body()
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

    // Goals, profile and unit count as saved only when the ring reads them back.
    // Falling back to the requested value when the read-back failed showed a
    // setting as saved that never reached the ring — it reverted on the next
    // refresh. The firmware acknowledges all three writes, so no answer is a
    // failure, not an "unacknowledged write".

    func setGoals(_ goals: RingGoals) async throws {
        try await write(.writeGoals(goals))
        guard let saved = await read(.readGoals, RingDecode.goals) else { throw RingError.timeout(RingOp.goals) }
        settings.goals = saved
        guard saved.steps == goals.steps, saved.calories == goals.calories,
              saved.distanceMeters == goals.distanceMeters else { throw RingError.rejected(RingOp.goals) }
    }

    func setProfile(_ profile: RingProfile) async throws {
        try await write(.writeProfile(profile))
        guard let saved = await read(.readProfile, RingDecode.profile) else { throw RingError.timeout(RingOp.profile) }
        settings.profile = saved
        guard saved.sex == profile.sex, saved.age == profile.age, saved.heightCm == profile.heightCm,
              saved.weightKg == profile.weightKg else { throw RingError.rejected(RingOp.profile) }
    }

    func setTemperatureUnit(celsius: Bool) async throws {
        try require(capabilities.anyTemperature, "temperature units")
        try await write(.writeTemperatureUnit(celsius: celsius))
        guard let saved = await read(.readTemperatureUnit, RingDecode.temperatureUnit) else {
            throw RingError.timeout(RingOp.temperatureUnit)
        }
        settings.temperatureUnit = saved
        guard saved.celsius == celsius else { throw RingError.rejected(RingOp.temperatureUnit) }
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
    /// Whether a shake is bound to anything, so the detector is only armed when it has work.
    var wantsShake: () -> Bool = { false }
    /// Whether the ring acknowledged arming its shake detector.
    @Published private(set) var shakeArmed = false

    /// Turns the ring's shake detector on or off. It refuses while the ring is charging, so this
    /// is sent again whenever the input mode is applied.
    func setShakeDetector(_ on: Bool) async {
        guard transport.link?.isLinkReady == true else { return }
        // The ring drops this silently while it is charging, or before it is fully up, so wait
        // for the ack and say which happened — an unarmed detector simply never fires.
        let reply = try? await transport.perform(.shakeDetector(on), until: .single)
        shakeArmed = on && reply?.isEmpty == false
        log.note("Ring shake detector",
                 reply?.isEmpty == false ? (on ? "armed" : "off")
                                         : "no answer — the ring refuses this while charging")
    }

    func setInputMode(_ mode: RingInputMode) async {
        guard transport.link?.isLinkReady == true else { return }
        // The reporting channel only matters when the presses should reach this app.
        _ = try? await transport.perform(.inputReporting(mode == .jarvis), until: .single)
        await setShakeDetector(mode == .jarvis && wantsShake())
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

    func sendRawBigData(cmd: UInt8, payload: [UInt8], until: RingUntil = .idle) async throws -> [RingInbound] {
        try await transport.perform(.bigData(cmd, payload), until: until)
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
        if type == .heartRate { armLiveSwitch() }
    }

    /// After the wear check, hand a heart rate over to real-time mode.
    private func armLiveSwitch() {
        liveSwitchTask?.cancel()
        let wait = heartRateWearCheck
        liveSwitchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, let running = self.measurement, running.isActive,
                  running.type == .heartRate, running.value == nil else { return }
            // Real-time mode keeps the sensor on until it is told to stop, even
            // across a dropped link — the stop is owed from this moment.
            self.realtimeStopOwed = true
            self.streamingHeartRate = true
            _ = try? await self.transport.perform(.realtimeHeartRate(true), until: .none)
        }
    }

    func cancelMeasurement() {
        finishMeasurement(.cancelled)
    }

    /// Forget a measurement that has finished.
    ///
    /// The result is worth showing for a moment and then gone: a card still
    /// reading "85 bpm" from a visit half an hour ago looks like a live reading.
    /// A running measurement is never dropped.
    func clearFinishedMeasurement() {
        guard measurement?.isActive != true else { return }
        measurement = nil
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
        // A reading that has a number is a result, however long it took to settle.
        if running.value != nil {
            finishMeasurement(.done)
        } else {
            finishMeasurement(.timedOut, detail: "no reading from the ring")
        }
    }

    /// A reading from real-time mode. Nothing in the app asks for these now, but a ring left
    /// streaming by an older build still sends them, and a real pulse is worth keeping.
    private func handleRealtime(_ reading: RingMeasurementReading) {
        if streamingHeartRate, var running = measurement, running.isActive, running.type == .heartRate {
            // Error 2: charging, or no sensor contact.
            if reading.errorCode != 0 {
                finishMeasurement(.notWorn, detail: "the ring is not on a finger")
                return
            }
            if reading.value > 0 {
                if running.skinContactAt == nil { running.skinContactAt = Date() }
                if running.firstValueAt == nil { running.firstValueAt = Date() }
                running.value = reading.value
                measurement = running
                if settleTimer == nil { armSettleTimer() }
            }
        }
        guard reading.errorCode == 0, reading.value > 0 else { return }
        let live = RingLiveReading(value: Double(reading.value), date: Date())
        liveHeartRate = live
        onLiveReading?(.heartRate, live)
    }

    private func handleMeasurement(_ reading: RingMeasurementReading) {
        guard var running = measurement, running.isActive, reading.type == running.type.rawValue else { return }
        // Error 1: the ring is not on a finger — it says so 3–7 s into a
        // reading — or it is charging, which it refuses outright.
        if reading.errorCode == 1 {
            finishMeasurement(.notWorn, detail: "the ring is not on a finger")
            return
        }
        if reading.errorCode != 0 {
            finishMeasurement(.failed, detail: "ring error \(reading.errorCode)")
            return
        }
        let hasValue = running.type == .bloodPressure ? reading.systolic > 0 : reading.value > 0
        if running.skinContactAt == nil, reading.signal > 0 || hasValue {
            running.skinContactAt = Date()
            measurement = running
        }
        guard hasValue else { return }
        running.value = reading.value
        if reading.systolic > 0 { running.systolic = reading.systolic }
        if reading.diastolic > 0 { running.diastolic = reading.diastolic }
        if running.type == .temperature { running.celsius = reading.celsius }
        if running.firstValueAt == nil { running.firstValueAt = Date() }
        measurement = running

        // A health check streams until its own window closes. Everything else
        // stays live for `measurementSettle` after its first number — the way a
        // watch warms up and then shows the reading moving — and finishes on
        // the latest value. Stopping on the first threw the rest away.
        if running.type != .healthCheck, settleTimer == nil { armSettleTimer() }
    }

    /// Ends the live window after the first value.
    private func armSettleTimer() {
        let window = measurementSettle
        settleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self, self.measurement?.isActive == true else { return }
            self.finishMeasurement(.done)
        }
    }

    private func finishMeasurement(_ phase: RingMeasurementState.Phase, detail: String? = nil, sendStop: Bool = true) {
        guard var running = measurement, running.isActive else { return }
        measurementTimer?.cancel()
        settleTimer?.cancel()
        settleTimer = nil
        liveSwitchTask?.cancel()
        keepAliveTask?.cancel()
        let stopRealtime = streamingHeartRate
        streamingHeartRate = false
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
        if stopRealtime {
            Task { [weak self] in _ = await self?.sendRealtimeStop() }
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
            guard let reading = RingDecode.measurement(inbound.payload) else { return }
            // Real-time mode answers on the same opcode, but it is not a one-shot measurement:
            // nothing is waiting on these, and dropping them left the wear status and the live
            // heart rate empty while the ring was pushing a reading a second.
            if reading.type == RingOp.realtimeHeartRateType {
                handleRealtime(reading)
            } else {
                handleMeasurement(reading)
            }
        case RingOp.calibration:
            // Subtype 3 of the 0xA1 telemetry burst is the newest accelerometer sample.
            if let a = RingDecode.accelFromTelemetry(inbound.payload) {
                liveAccelerometer = a
                accelerometerSupported = true
            }
            if !accelStreaming { handleCalibration(RingDecode.calibration(inbound.payload)) }
        case RingOp.packageLength:
            chunkSize = max(RingProtocol.minimumChunk, Int(inbound.payload.first ?? 0))
        case RingOp.findPhone:
            let active = inbound.payload.first == 1
            findPhoneActive = active
            onFindPhone?(active)
        case RingOp.camera:
            // `1` the ring asking for the camera (a tap, in its photo mode), `2` the shake
            // detector firing, `3` the camera closing. A shake is its own gesture and must not
            // reach the press counter — it would read as an extra tap.
            switch inbound.payload.first {
            case 2: noteShake()
            case 1: noteInput(.tap)
            default: break
            }
        case RingOp.ppgData:
            livePPG = (livePPG + inbound.payload.map(Int.init)).suffix(180)
        case RingOp.musicCommand:
            // In the ring's music mode every tap and swipe arrives as one of these.
            if let input = RingInput(musicAction: Int(inbound.payload.first ?? 0)) { noteInput(input) }
        default:
            break
        }
    }

    /// How long to wait for another press before deciding what the gesture was. The ring's own
    /// re-arm delay sets the floor; the log prints the measured gap and this is settable per ring.
    var pressWindow: () -> TimeInterval = { 2.0 }
    /// The longest press run anything is bound to. A burst that reaches it is decided at once,
    /// and with nothing beyond a single press bound there is no burst at all.
    var maxBoundPresses: () -> Int = { 1 }
    /// What a gesture is currently set to run, for the gesture monitor.
    var actionSummary: (RingInput) -> String? = { _ in nil }
    private var presses = RingPressCounter()
    private var pressTask: Task<Void, Never>?

    /// A ring with no touch surface sends one kind of press, so presses in succession become
    /// single, double and triple — three inputs out of one gesture. `RingPressCounter` holds
    /// the rules; this is the plumbing: cancel the pending decision, act on the outcome, log
    /// the measured gap either way.
    /// How long after a shake the ring's tap detector keeps rattling. A shake is sustained
    /// motion, so it trips the click interrupt too; those clicks are not presses.
    private static let shakeGuard: TimeInterval = 2.5
    private var lastShakeAt: Date?

    /// A shake the ring reports, arbitrated against whatever tapping is in flight.
    ///
    /// The two detectors share one accelerometer and overlap in both directions: a shake trips
    /// the tap detector, and tapping the ring repeatedly builds enough motion to trip the shake
    /// detector. Neither can be turned down from the phone, so they are told apart by what else
    /// is happening — a shake that lands in the middle of a run of presses is the tapping, and
    /// anything else is a real shake, which takes the stray press it caused with it.
    private func noteShake() {
        if presses.count >= 2 {
            note(.ignored, "Shake ignored", "you were already \(presses.count) presses into a tap")
            log.note("Ring shake ignored", "\(presses.count) presses in flight — that was tapping")
            return
        }
        lastShakeAt = Date()
        if presses.count > 0 {
            // The shake's own motion tripped the tap detector; that click was not a press.
            pressTask?.cancel()
            pressTask = nil
            presses.discard()
        }
        note(.shake, "Shake", outcomeNote(.shake))
        deliver(.shake)
    }

    private func noteInput(_ input: RingInput) {
        guard input.isPress else {
            deliver(input)
            return
        }
        if let shake = lastShakeAt, Date().timeIntervalSince(shake) < Self.shakeGuard {
            note(.ignored, "Tap ignored", "inside the shake that just ran")
            log.note("Ring press ignored", "inside the shake guard")
            return
        }
        // Only what is actually bound is waited for: with nothing on a double or triple press
        // there is nothing to disambiguate, and a tap runs the moment it lands.
        let outcome = presses.press(at: Date(), window: pressWindow(), maxPresses: maxBoundPresses())
        if case .echo = outcome {} else { lastPressGap = outcome.gap }
        switch outcome {
        case .echo(let gap):
            // Not a second press: the ring cannot report two taps this close together.
            note(.ignored, "Tap ignored", String(format: "%.2fs behind the last — a repeat", gap))
            log.note("Ring press ignored", String(format: "%.2fs behind the last — a repeat of it", gap))
        case .decided(let resolved, let gap):
            pressTask?.cancel()
            pressTask = nil
            note(.press, "Tap \(presses.count + 1) reported", detail(gap))
            note(.resolved, resolved.label, outcomeNote(resolved))
            log.note("Ring \(resolved.label.lowercased())", detail(gap) + ", run now")
            deliver(resolved)
        case .waiting(let deadline, let gap):
            note(.press, "Tap \(presses.count) reported",
                 detail(gap) + String(format: " · deciding in %.1fs", deadline.timeIntervalSinceNow))
            log.note("Ring press", detail(gap) + String(format: " — deciding in %.1fs", deadline.timeIntervalSinceNow))
            pressTask?.cancel()
            pressTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                let resolved = self.presses.take()
                self.note(.resolved, resolved.label, self.outcomeNote(resolved))
                self.deliver(resolved)
            }
        }
    }

    /// What the ring's last press looked like, so the settings screen can show the real gap
    /// rather than leaving the user to guess why a double press did not group.
    @Published private(set) var lastPressGap: TimeInterval?

    /// The raw gesture stream, newest first — every press and shake as the ring sent it, and
    /// what Jarvis made of it. The two detectors overlap in the hardware, so this is the only
    /// way to see which one actually fired.
    @Published private(set) var gestureFeed: [RingGestureEvent] = []

    /// What the action bound to a gesture did, and how long it took — reported by whoever ran
    /// it. Between this and the "run now" line above it, the monitor accounts for every
    /// millisecond the phone is responsible for; anything left over is the ring taking its time
    /// to send the tap in the first place.
    func noteGestureRun(_ input: RingInput, _ detail: String) {
        note(.ran, input.label, detail)
    }

    private func note(_ kind: RingGestureEvent.Kind, _ title: String, _ detail: String) {
        gestureFeed.insert(RingGestureEvent(kind: kind, title: title, detail: detail, date: Date()), at: 0)
        if gestureFeed.count > 12 { gestureFeed.removeLast(gestureFeed.count - 12) }
    }

    /// What will come of a gesture: the action it runs, or that nothing is set for it. A row
    /// left on "Nothing" is the commonest reason a gesture looks broken.
    private func outcomeNote(_ input: RingInput) -> String {
        actionSummary(input) ?? "nothing set for this"
    }

    /// The gap between this press and the one before it — the only way to tell "the ring
    /// dropped a press" from "the window was too short", so it goes in the log every time.
    private func detail(_ gap: TimeInterval?) -> String {
        gap.map { String(format: "%.1fs after the last", $0) } ?? "first"
    }

    /// The ring's firmware keeps real-time heart-rate mode — and its optical sensor —
    /// running until it is told to stop; a dropped link does not stop it. Nothing in the app
    /// starts that mode any more, but a build that did may have left the ring streaming, so a
    /// stop is owed until one is acknowledged, and the debt survives a relaunch.
    private var realtimeStopOwed: Bool {
        get { defaults.bool(forKey: "jc.ring.realtimeStopOwed") }
        set { defaults.set(newValue, forKey: "jc.ring.realtimeStopOwed") }
    }

    /// Records that the ring may be streaming. A heart-rate reading does this
    /// itself when it switches to real-time mode; the tests use it directly.
    func noteRealtimeOwed() {
        realtimeStopOwed = true
    }

    /// Stops real-time mode and waits for the ring's answer.
    private func sendRealtimeStop() async -> Bool {
        let answered = (try? await transport.perform(.realtimeHeartRate(false), until: .single)) != nil
        realtimeStopOwed = !answered
        return answered
    }

    private func deliver(_ input: RingInput) {
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
