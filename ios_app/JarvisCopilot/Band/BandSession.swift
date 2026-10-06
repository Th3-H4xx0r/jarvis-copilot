import Foundation

/// The band's profile: what its step, calorie and sleep sums are computed from.
struct BandProfile: Codable, Equatable {
    var heightCm: Int
    var weightKg: Int
    var age: Int
    var male: Bool
    var stepGoal: Int
    var sleepGoalMinutes: Int

    static let key = "jc.band.profile"

    /// The one set for the band, else the R12's or the X5's, else nothing (the band keeps its own).
    @MainActor static func current(defaults: UserDefaults = .standard) -> BandProfile? {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(BandProfile.self, from: data) {
            return saved
        }
        let hub = WearablesHub.shared
        if let r = hub.ring.session.settings.profile, r.heightCm > 0 {
            // The R12 keeps sex as 1 = female.
            return BandProfile(heightCm: r.heightCm, weightKg: r.weightKg, age: r.age, male: r.sex != 1,
                               stepGoal: 10_000, sleepGoalMinutes: 480)
        }
        if let x = hub.x5.session.profile, x.heightCm > 0 {
            return BandProfile(heightCm: x.heightCm, weightKg: x.weightKg, age: x.age, male: x.male,
                               stepGoal: 10_000, sleepGoalMinutes: 480)
        }
        return nil
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// One line of the band's command log (newest first), for `band_get_log` and the settings screen.
struct BandLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let outgoing: Bool
    let hex: String
}

/// The band over a `BandTransport`: setup (handshake, time, profile, battery, settings),
/// spot measurements, the heart-rate stream a workout runs on, app sport control, find,
/// alarms, reminders, phone alerts and every other setting the band reports it supports.
///
/// The Veepoo band answers nothing until the A1 handshake passes, and sends its feature tables
/// and current settings as part of that reply.
@MainActor
final class BandSession: ObservableObject {
    let transport = BandTransport()

    @Published private(set) var handshake: BandHandshake?
    @Published private(set) var features: BandFeatures?
    @Published private(set) var battery: RingBattery?
    @Published private(set) var product: BandProduct?
    @Published private(set) var settings: BandSettings?
    @Published private(set) var alerts: BandAlertSwitches?
    @Published private(set) var isSetUp = false
    /// The measurement running now, if any.
    @Published private(set) var measuring: BandMeasure?
    @Published private(set) var lastReading: BandReading?
    /// Heart rate from a spot check's live stream, nil when none.
    @Published private(set) var liveHeartRate: Int?
    /// The reminder settings, as the band last reported them (`refreshReminders`).
    @Published private(set) var sedentary: BandSedentary?
    @Published private(set) var heartRateAlarm: BandHeartRateAlarm?
    @Published private(set) var raiseToWake: BandRaiseToWake?
    @Published private(set) var oxygenSchedule: BandOxygenSchedule?
    @Published private(set) var bpCalibration: BandBPCalibration?
    @Published private(set) var componentCalibration: BandBloodComponentCalibration?
    @Published private(set) var glucoseCalibration: BandGlucoseCalibration?
    @Published private(set) var log: [BandLogEntry] = []
    /// True while the band buzzes to be found. It stops on `find(false)`, when the wearer
    /// presses it, or on its own timeout — the band says which (`B5`).
    @Published private(set) var finding = false
    /// The ECG running now: its waveform (raw counts) and heart rate each second, for the live
    /// view and the report kept at the end.
    @Published private(set) var ecgSamples: [Int] = []
    @Published private(set) var ecgHeartRates: [Int] = []
    /// The QTc and HRV the band reports each second: a reading that stops before the band's
    /// analysis still has them.
    private(set) var ecgQtcs: [Int] = []
    private(set) var ecgHrvs: [Int] = []
    private(set) var ecgSampleRate = 250

    /// The band's own workout reports (`DA 03`), between the adapter's polls.
    var onSportStatus: ((BandSportStatus) -> Void)?
    /// Every reading that ended (a value or why not), however it was asked for — kept in the day.
    var onMeasured: ((BandReading) -> Void)?
    /// Turns the ECG waveform channel on (an ECG starting) or off (it ended).
    var onEcgWave: ((Bool) -> Void)?
    var calendar = Calendar.current
    var now: () -> Date = Date.init

    init() {
        transport.onFrame = { [weak self] frame in self?.unsolicited(frame) }
        transport.onTraffic = { [weak self] outgoing, frame in self?.note(outgoing, frame) }
    }

    func attach(_ link: BandLink) { transport.link = link }

    /// Forget: nothing of this band's identity survives into the next one.
    func forgetIdentity() {
        handshake = nil
        features = nil
        settings = nil
        alerts = nil
        product = nil
    }

    func linkDropped() {
        transport.linkDropped()
        isSetUp = false
        measuring = nil
        liveHeartRate = nil
        finding = false
    }

    // MARK: Setup

    /// Handshake, then the clock, the profile, battery, product and settings.
    func runSetup(profile: BandProfile?) async throws {
        let replies = try await transport.perform(BandRequest.password(at: now(), calendar: calendar),
                                                  accepts: BandOp.handshakeReplies, timeout: 6) { frames in
            frames.contains { $0.first == BandOp.password }
        }
        guard let reply = replies.last(where: { $0.first == BandOp.password }),
              let shake = BandDecode.password(reply), shake.ok else {
            throw BandError.refused("The band refused the handshake.")
        }
        handshake = shake
        features = BandDecode.features(replies.filter { $0.first != BandOp.password })
        if let s = BandDecode.settings(replies) { settings = s }
        if let a = BandDecode.alerts(replies) { alerts = a }
        _ = try? await transport.perform(BandRequest.syncTime(now(), hour24: settings?.hour24 ?? true, calendar: calendar))
        if let profile {
            _ = try? await transport.perform(BandRequest.profile(
                heightCm: profile.heightCm, weightKg: profile.weightKg, age: profile.age, male: profile.male,
                stepGoal: profile.stepGoal, sleepGoalMinutes: profile.sleepGoalMinutes))
        }
        await refreshBattery()
        let productRequest = BandRequest.productInfo()
        if let frames = try? await transport.perform(productRequest, timeout: 3, until: { frames in
            BandDecode.isComplete(frames, for: productRequest)
        }) {
            product = BandDecode.product(frames)
        }
        isSetUp = true
    }

    func refreshBattery() async {
        guard let frame = try? await transport.perform(BandRequest.battery()).first,
              let decoded = BandDecode.battery(frame) else { return }
        battery = decoded.ring
    }

    /// Whether the band said it has `feature` (nil when not known yet — assume it does).
    func supports(_ feature: String) -> Bool {
        features.map { $0.supports(feature) } ?? true
    }

    // MARK: Measurements

    /// A spot reading, followed until it ends: a value, the band's refusal (busy, not worn,
    /// charging, low battery) or failure, or — when the band leaves it unfinished — `failed`
    /// with a reason: quiet for a while, the electrode lead off too long, or past the deadline
    /// (`type.timeout`, or `seconds` when the caller has less). What it ended as comes back and
    /// stays as `lastReading`. Cancelled, it throws and puts the previous reading back.
    func measure(_ type: BandMeasure, seconds: TimeInterval? = nil) async throws -> BandReading {
        guard measuring == nil else { throw BandError.refused("The band is already measuring.") }
        measuring = type
        defer { measuring = nil }
        let before = lastReading
        if type == .ecg {
            ecgSamples = []
            ecgHeartRates = []
            ecgQtcs = []
            ecgHrvs = []
            ecgWaveFrames = 0
            onEcgWave?(true)
        }
        defer { if type == .ecg { onEcgWave?(false) } }
        let start = BandRequest.measure(type, on: true)
        var run = BandMeasureRun(type, from: now(), seconds: seconds)
        // Every frame's reading from now on, in order — a poll would miss the parts of a result.
        // (`dropFirst`: the publisher replays the current one, maybe the last try's.)
        let watch = $lastReading.dropFirst().sink { [weak self] r in
            guard let self, let r else { return }
            run.add(r, at: self.now())
        }
        // Whatever happens, the band is told to stop — a test left running drains it.
        defer {
            watch.cancel()
            transport.send(BandRequest.measure(type, on: false))
        }
        // The first reply comes back to the request; the rest of the stream is unsolicited.
        let first = try await transport.perform(start, accepts: BandOp.measurementReplies, timeout: 6)
        for frame in first {
            // The ECG's start reply names its sample rate (bytes 4–5).
            if type == .ecg, frame.count > 5, frame[0] == BandOp.ecgBody, frame[1] == 1, frame[3] == 0 {
                let rate = Int(frame[4]) | Int(frame[5]) << 8
                if (100...1000).contains(rate) { ecgSampleRate = rate }
            }
            if let r = BandDecode.measurement(frame, at: now()) { run.add(r, at: now()) }
        }
        while !run.ended {
            // The wear sheet's "Not now": no half-finished reading is left showing.
            if Task.isCancelled {
                watch.cancel()
                lastReading = before
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(250))
            run.tick(at: now())
        }
        watch.cancel()
        guard let result = run.reading else { throw BandError.timeout(start.first ?? 0) }
        lastReading = result
        onMeasured?(result)
        return result
    }

    // MARK: Control

    /// App sport control: true when the band accepted it.
    func sport(_ op: BandSportOp) async -> Bool {
        guard let frame = try? await transport.perform(BandRequest.sport(op), timeout: 3).first else { return false }
        return BandDecode.sportAck(frame) ?? false
    }

    /// The running app sport, as the band counts it (poll every few seconds once started).
    func sportStatus() async -> BandSportStatus? {
        let request = BandRequest.sportStatus()
        // A `DA 03` report can land between the parts of the `DA 02` reply: it is the band's
        // own update, not part of this one.
        let isPoll: ([UInt8]) -> Bool = { $0.count > 1 && $0[1] == 0x02 }
        guard let frames = try? await transport.perform(request, accepts: [BandOp.sportControl], timeout: 3, until: {
            BandDecode.isComplete($0.filter(isPoll), for: request)
        }) else { return nil }
        for report in frames where !isPoll(report) {
            if let status = BandDecode.sportStatus([report]) { onSportStatus?(status) }
        }
        return BandDecode.sportStatus(frames.filter(isPoll))
    }

    /// How many waveform frames this ECG brought (the log would drown in them; this is its note).
    private(set) var ecgWaveFrames = 0

    /// A frame from the waveform channel while an ECG runs.
    func ecgWave(_ frame: [UInt8]) {
        guard measuring == .ecg else { return }
        ecgWaveFrames += 1
        if ecgWaveFrames == 1 { note(false, frame) }
        ecgSamples.append(contentsOf: BandEcgSignal.waveSamples(frame))
        let cap = ecgSampleRate * 120
        if ecgSamples.count > cap { ecgSamples.removeFirst(ecgSamples.count - cap) }
    }

    /// A running ECG's waveform and heart rate, for previews and render tests.
    func seedEcgForTests(samples: [Int], heartRates: [Int]) {
        ecgSamples = samples
        ecgHeartRates = heartRates
    }

    /// Starts (`B5 0A`) or stops (`B5 0B`) the band buzzing to be found.
    func find(_ on: Bool) async throws {
        let reply = try await transport.perform(BandRequest.find(on: on), timeout: 3).first
        finding = reply.flatMap(BandDecode.find) ?? on
    }

    func readSteps() async -> BandSteps? {
        guard let frame = try? await transport.perform(BandRequest.readSteps(), timeout: 3).first else { return nil }
        return BandDecode.steps(frame)
    }

    // MARK: Settings

    func readAlarms() async throws -> [BandAlarm] {
        let request = BandRequest.readAlarms()
        let frames = try await transport.perform(request, timeout: 4) { BandDecode.isComplete($0, for: request) }
        return BandDecode.alarms(frames)
    }

    /// A setting write, refused unless the band says yes (when its reply says either).
    private func write(_ frame: [UInt8], timeout: TimeInterval = 4,
                       until: @escaping ([[UInt8]]) -> Bool = { !$0.isEmpty }) async throws {
        let replies = try await transport.perform(frame, timeout: timeout, until: until)
        if let ok = replies.compactMap(BandDecode.ack).last, !ok {
            throw BandError.refused("The band refused that setting.")
        }
    }

    func setAlarm(_ alarm: BandAlarm) async throws {
        try await write(BandRequest.setAlarm(alarm))
    }

    func deleteAlarm(_ alarm: BandAlarm) async throws {
        try await write(BandRequest.deleteAlarm(alarm))
    }

    /// The sitting reminder, heart-rate alarm, raise-to-wake and overnight SpO2, read back.
    func refreshReminders() async {
        if let f = try? await transport.perform(BandRequest.readSedentary(), timeout: 3).first { sedentary = BandDecode.sedentary(f) }
        if let f = try? await transport.perform(BandRequest.readHeartRateAlarm(), timeout: 3).first {
            heartRateAlarm = BandDecode.heartRateAlarm(f)
        }
        if let f = try? await transport.perform(BandRequest.readRaiseToWake(), timeout: 3).first { raiseToWake = BandDecode.raiseToWake(f) }
        if let f = try? await transport.perform(BandRequest.readBloodOxygenAuto(), timeout: 3).first {
            oxygenSchedule = BandDecode.bloodOxygenAuto(f)
        }
    }

    func readSedentary() async throws -> BandSedentary? {
        guard let frame = try await transport.perform(BandRequest.readSedentary(), timeout: 3).first else { return nil }
        return BandDecode.sedentary(frame)
    }

    func setSedentary(_ s: BandSedentary) async throws {
        try await write(BandRequest.sedentary(s), timeout: 3)
        sedentary = s
    }

    func setHeartRateAlarm(enabled: Bool, high: Int, low: Int) async throws {
        try await write(BandRequest.heartRateAlarm(enabled: enabled, high: high, low: low), timeout: 3)
        heartRateAlarm = BandHeartRateAlarm(enabled: enabled, high: high, low: low)
    }

    func setRaiseToWake(_ on: Bool) async throws {
        try await write(BandRequest.raiseToWake(on), timeout: 3)
        raiseToWake?.enabled = on
    }

    /// The switches span two of the band's frames; each is written and answered in turn.
    func setAlerts(_ switches: BandAlertSwitches) async throws {
        for frame in BandRequest.alertsFrames(switches) {
            try await write(frame) { BandDecode.isComplete($0, for: frame) }
        }
        alerts = switches
    }

    /// One of the band's units, metric (°C, mmol/L, µmol/L) or not. A band without that unit
    /// is left alone.
    func setUnit(_ unit: BandSettings.Unit, metric: Bool) async throws {
        guard let current = settings, let next = current.with(unit, metric: metric), next != current else { return }
        try await writeSettings(next)
    }

    func writeSettings(_ s: BandSettings) async throws {
        for frame in BandRequest.writeSettingsFrames(s) {
            try await write(frame) { BandDecode.isComplete($0, for: frame) }
        }
        settings = s
    }

    func setBloodOxygenAuto(enabled: Bool, start: (h: Int, m: Int), end: (h: Int, m: Int)) async throws {
        try await write(BandRequest.bloodOxygenAuto(enabled: enabled, start: start, end: end), timeout: 3)
        oxygenSchedule?.enabled = enabled
    }

    // MARK: Calibration

    /// What the band's glucose estimate takes (its A7 glucose tag, as the Android SDK reads it):
    /// one reference (2, 3, 6), a reference per meal (4, 5, 7, 8, 9), or none.
    var glucoseCalibrationKind: BandGlucoseCalibration.Kind {
        switch features?.types["bloodGlucoseFunction"] ?? 0 {
        case 2, 3, 6: return .single
        case 4, 5, 7, 8, 9: return .meals
        default: return .none
        }
    }

    /// Blood pressure always; blood components when its tag is 2 (single calibration).
    var calibratesBloodPressure: Bool { features?.supports("blood_pressure") ?? false }
    var calibratesBloodComponents: Bool { features?.types["bloodComponentType"] == 2 }

    /// The three references, read back (each only where the band has it).
    func refreshCalibrations() async {
        if calibratesBloodPressure,
           let f = try? await transport.perform(BandRequest.readBloodPressureCalibration(), timeout: 3,
                                                until: { $0.contains { BandDecode.bloodPressureCalibration($0) != nil } }) {
            bpCalibration = f.compactMap(BandDecode.bloodPressureCalibration).last
        }
        if calibratesBloodComponents,
           let f = try? await transport.perform(BandRequest.readBloodComponentCalibration(), timeout: 3,
                                                until: { $0.contains { BandDecode.bloodComponentCalibration($0) != nil } }) {
            componentCalibration = f.compactMap(BandDecode.bloodComponentCalibration).last
        }
        switch glucoseCalibrationKind {
        case .meals:
            if let f = try? await transport.perform(BandRequest.readGlucoseMealCalibration(), timeout: 4,
                                                    until: { BandDecode.glucoseMealCalibration($0) != nil }) {
                glucoseCalibration = BandDecode.glucoseMealCalibration(f)
            }
        case .single:
            if let f = try? await transport.perform(BandRequest.readGlucoseCalibration(), timeout: 3,
                                                    until: { $0.contains { BandDecode.glucoseCalibration($0) != nil } }) {
                glucoseCalibration = f.compactMap(BandDecode.glucoseCalibration).last
            }
        case .none:
            break
        }
    }

    func setBloodPressureCalibration(_ c: BandBPCalibration) async throws {
        let replies = try await transport.perform(BandRequest.bloodPressureCalibration(c), timeout: 4) { frames in
            frames.contains { $0.first == BandOp.bloodPressureCalibration }
        }
        guard replies.contains(where: { $0.count > 1 && $0[0] == BandOp.bloodPressureCalibration && $0[1] == 1 }) else {
            throw BandError.refused("The band refused the blood-pressure reference.")
        }
        bpCalibration = c
    }

    func setBloodComponentCalibration(_ c: BandBloodComponentCalibration) async throws {
        let replies = try await transport.perform(BandRequest.bloodComponentCalibration(c), timeout: 4) { frames in
            frames.contains { $0.count > 3 && $0[0] == BandOp.bloodComponent && $0[1] == 2 }
        }
        guard let saved = replies.compactMap(BandDecode.bloodComponentCalibration).last else {
            throw BandError.refused("The band refused the blood-test reference.")
        }
        componentCalibration = saved
    }

    func setGlucoseCalibration(_ c: BandGlucoseCalibration) async throws {
        switch glucoseCalibrationKind {
        case .meals:
            // Two frames; the band answers each, `89 03 01 ok n total`, and is done at n = total.
            for frame in BandRequest.glucoseMealCalibrationFrames(c) {
                let replies = try await transport.perform(frame, timeout: 4) { frames in
                    frames.contains { $0.count > 3 && $0[0] == BandOp.glucoseStress && $0[1] == 3 && $0[2] == 1 }
                }
                guard replies.contains(where: { $0.count > 3 && $0[1] == 3 && $0[2] == 1 && $0[3] == 1 }) else {
                    throw BandError.refused("The band refused the glucose references.")
                }
            }
        case .single:
            let replies = try await transport.perform(BandRequest.glucoseCalibration(c), timeout: 4) { frames in
                frames.contains { $0.count > 3 && $0[0] == BandOp.glucoseStress && $0[1] == 2 }
            }
            guard replies.contains(where: { BandDecode.glucoseCalibration($0) != nil }) else {
                throw BandError.refused("The band refused the glucose reference.")
            }
        case .none:
            throw BandError.refused("This band takes no glucose reference.")
        }
        glucoseCalibration = c
    }

    func setSkinTone(_ level: Int) async throws {
        // Skin tone lives in the settings frame: rewrite the band's own, changed only there.
        let request = settings.map { BandRequest.skinTone(level, settings: $0) } ?? BandRequest.skinTone(level)
        try await write(request, timeout: 3)
    }

    func setCamera(_ on: Bool) async throws {
        _ = try await transport.perform(BandRequest.camera(on), timeout: 3)
    }

    func clearData() async throws {
        _ = try await transport.perform(BandRequest.clearData(), timeout: 5)
    }

    func setProfile(_ profile: BandProfile) async throws {
        try await write(BandRequest.profile(
            heightCm: profile.heightCm, weightKg: profile.weightKg, age: profile.age, male: profile.male,
            stepGoal: profile.stepGoal, sleepGoalMinutes: profile.sleepGoalMinutes), timeout: 3)
        profile.save()
    }

    // MARK: History

    /// One day's records, `day` 0 = today, 1 = yesterday, 2 = the day before.
    func readDaily(day: Int) async throws -> [BandDailyRecord] {
        let request = BandRequest.readDaily(day: day, package: 1)
        let frames = try await transport.perform(request, accepts: BandOp.dailyReplies, timeout: 20) {
            BandDecode.isComplete($0, for: request)
        }
        return BandDecode.daily(frames, day: day, calendar: calendar, now: now())
    }

    func readSleep(day: Int) async throws -> [BandSleep] {
        let request = BandRequest.readSleep(day: day)
        let frames = try await transport.perform(request, accepts: BandOp.sleepReplies, timeout: 15) {
            BandDecode.isComplete($0, for: request)
        }
        return BandDecode.sleep(frames, calendar: calendar)
    }

    // MARK: Unsolicited

    private func unsolicited(_ frame: [UInt8]) {
        if let reading = BandDecode.measurement(frame) {
            // A late frame (the stop's own reply) must not replace the reading that ended.
            guard measuring == reading.measure else { return }
            lastReading = reading
            if reading.measure == .ecg, reading.part == nil, !reading.ended {
                if let hr = reading.heartRate, (30...250).contains(hr) { ecgHeartRates.append(hr) }
                if let qtc = reading.qtcMs { ecgQtcs.append(qtc) }
                if let hrv = reading.hrv { ecgHrvs.append(hrv) }
            }
            if reading.measure == .heartRate { liveHeartRate = reading.heartRate }
            return
        }
        if frame.first == BandOp.sportControl, let status = BandDecode.sportStatus([frame]) {
            onSportStatus?(status)
            return
        }
        // Found (the wearer pressed the band) or timed out.
        if let searching = BandDecode.find(frame) {
            finding = searching
            return
        }
        if let level = BandDecode.battery(frame) {
            battery = level.ring
        }
    }

    private func note(_ outgoing: Bool, _ frame: [UInt8]) {
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        log.insert(BandLogEntry(date: now(), outgoing: outgoing, hex: hex), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }
}
