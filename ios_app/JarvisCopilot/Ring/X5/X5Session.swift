import Foundation

/// A gesture as it arrived, so screens can show which row it landed on.
struct X5GestureEvent: Equatable {
    let gesture: X5Gesture
    let date: Date
}

/// A spot measurement in progress or just finished.
struct X5Measurement: Equatable {
    var type: RingMeasurementType
    var startedAt: Date
    var seconds: Int
    var latest: Double?
    var result: Double?
    var failed: String?
    var isActive: Bool
}

/// Features the X5's sheet doesn't promise, switched on only when the ring answers for them.
enum X5Feature: String, Codable, CaseIterable {
    case stepGoal, manualSpO2, ppg

    var label: String {
        switch self {
        case .stepGoal: return "Step goal"
        case .manualSpO2: return "Manual SpO₂ history"
        case .ppg: return "PPG waveform"
        }
    }
}

/// How long the touch surface stays awake before the ring powers it down.
enum X5AwakePolicy: Codable, Equatable, Hashable {
    case minutes(Int)
    /// Kept awake for as long as the ring is connected: re-armed whenever it times out.
    case always

    static let choices: [X5AwakePolicy] = [.minutes(1), .minutes(5), .minutes(30), .always]

    /// The delay sent to the ring. "Always" sends an hour and re-arms on each timeout.
    var seconds: Int {
        switch self {
        case .minutes(let m): return m * 60
        case .always: return 3600
        }
    }

    var label: String {
        switch self {
        case .minutes(let m): return m == 1 ? "1 minute" : "\(m) minutes"
        case .always: return "Always while connected"
        }
    }
}

/// The X5's protocol state over one link: setup, live data, spot measurements, gestures, the
/// touch surface, monitoring, maintenance and probing. Link-agnostic (`attach`), like `RingSession`.
@MainActor
final class X5Session: ObservableObject {
    let transport: RingTransport
    let log = RingLog(describe: X5LogDecoder.describe)

    @Published private(set) var battery: RingBattery?
    @Published private(set) var millivolts: Int?
    @Published private(set) var firmware: X5Firmware?
    @Published private(set) var mac: String?
    @Published private(set) var profile: X5Profile?
    @Published private(set) var monitoring: [X5MonitorType: X5Monitoring] = [:]
    @Published private(set) var hid: X5HIDState?
    @Published private(set) var live: X5Live?
    @Published private(set) var liveOn = false
    @Published private(set) var lastGesture: X5GestureEvent?
    @Published private(set) var measurement: X5Measurement?
    @Published private(set) var features: Set<X5Feature> = []
    @Published private(set) var goal: Int?
    @Published private(set) var skinTemp: Double?
    @Published private(set) var isSetUp = false
    @Published private(set) var touchAsleep = false

    var onGesture: ((X5Gesture) -> Void)?
    var onWorkoutTick: ((X5WorkoutTick) -> Void)?
    /// What the touch surface should be doing, from the inputs screen.
    var wantedHID: () -> (enabled: Bool, mode: X5HIDMode) = { (true, .keys) }
    var awakePolicy: X5AwakePolicy = .always
    /// A screen showing live data keeps the stream on past a measurement.
    var holdsLive = false

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private var measurementValues: [Double] = []
    private var lastRearm: Date?
    private static let liveStopOwedKey = "jc.x5.liveStopOwed"
    /// Gestures the same as the last one this close together are one gesture reported twice.
    static let gestureEchoWindow: TimeInterval = 0.15
    /// "Always awake" re-arms at most this often, so a ring that keeps timing out can't loop.
    static let rearmInterval: TimeInterval = 20

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         timing: RingTransport.Timing = RingTransport.Timing()) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        transport = RingTransport(timing: timing)
        transport.onFrame = { [log] frame in log.record(frame) }
        transport.onUnsolicited = { [weak self] inbound in self?.handle(inbound) }
    }

    func attach(_ link: RingLink) { transport.link = link }

    func linkDropped() {
        transport.linkDropped()
        liveOn = false
        isSetUp = false
        if measurement?.isActive == true { measurement?.isActive = false; measurement?.failed = "link dropped" }
    }

    // MARK: Setup

    func runSetup(deviceID: String) async throws {
        if defaults.bool(forKey: Self.liveStopOwedKey) {
            if (try? await transport.perform(.x5Live(false), until: .single)) != nil {
                defaults.set(false, forKey: Self.liveStopOwedKey)
                log.note("X5 sensor", "stopped live data left running on an earlier link")
            }
        }
        _ = try await transport.perform(.x5SetTime(now(), calendar: calendar), until: .single)
        if let p = try? await reply(.x5GetProfile) { profile = X5Decode.profile(p) }
        await refreshBattery()
        if let p = try? await reply(.x5Firmware) { firmware = X5Decode.firmware(p) }
        if let p = try? await reply(.x5Mac) { mac = X5Decode.mac(p) }
        await refreshMonitoring()
        let appliedKey = "jc.x5.monitoringApplied.\(deviceID)"
        if !defaults.bool(forKey: appliedKey) {
            var ok = true
            for m in Self.defaultMonitoring {
                do { try await setMonitoring(m) } catch { ok = false }
            }
            if ok { defaults.set(true, forKey: appliedKey) }
        }
        await refreshHID()
        await applyHID()
        if needsProbe(deviceID: deviceID) { await probe(deviceID: deviceID) } else { loadProbe(deviceID: deviceID) }
        isSetUp = true
    }

    /// HR every 10 min all day, HRV/stress every 30 min all day, SpO₂ every 30 min overnight.
    static let defaultMonitoring: [X5Monitoring] = [
        X5Monitoring(on: true, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59, weekdays: 0x7F,
                     intervalMinutes: 10, type: .heartRate),
        X5Monitoring(on: true, startHour: 0, startMinute: 0, endHour: 23, endMinute: 59, weekdays: 0x7F,
                     intervalMinutes: 30, type: .hrv),
        X5Monitoring(on: true, startHour: 22, startMinute: 0, endHour: 8, endMinute: 0, weekdays: 0x7F,
                     intervalMinutes: 30, type: .spo2),
    ]

    /// An X5 answers both of these in its own shape; anything else on FFF0 doesn't.
    func verifyIdentity() async -> Bool {
        guard let fw = try? await reply(.x5Firmware), let decoded = X5Decode.firmware(fw),
              let time = try? await reply(.x5GetTime), X5Decode.time(time, calendar: calendar) != nil else { return false }
        firmware = decoded
        return true
    }

    private func reply(_ request: RingRequest) async throws -> [UInt8] {
        guard let first = try await transport.perform(request, until: .single).first else {
            throw RingError.timeout(request.cmd)
        }
        return first.payload
    }

    func refreshBattery() async {
        guard let p = try? await reply(.x5Battery), let decoded = X5Decode.battery(p) else { return }
        battery = decoded.battery
        millivolts = decoded.millivolts
    }

    // MARK: Monitoring

    func refreshMonitoring() async {
        for type in [X5MonitorType.heartRate, .spo2, .hrv] {
            if let p = try? await reply(.x5GetMonitoring(type)), let m = X5Decode.monitoring(p) { monitoring[m.type] = m }
        }
    }

    func setMonitoring(_ m: X5Monitoring) async throws {
        _ = try await transport.perform(.x5SetMonitoring(m), until: .single)
        monitoring[m.type] = m
    }

    // MARK: Touch surface

    func refreshHID() async {
        if let p = try? await reply(.x5GetHID) { hid = X5Decode.hid(p) }
    }

    /// Writes the wanted touch mode and how long it stays awake.
    func applyHID() async {
        let wanted = wantedHID()
        let request = RingRequest.x5SetHID(enabled: wanted.enabled, mode: wanted.mode, awakeSeconds: awakePolicy.seconds)
        if (try? await transport.perform(request, until: .single)) != nil {
            hid = X5HIDState(enabled: wanted.enabled, mode: wanted.mode, awakeSeconds: awakePolicy.seconds)
            touchAsleep = false
            log.note("X5 touch → \(wanted.enabled ? "\(wanted.mode)" : "off")", awakePolicy.label)
        }
    }

    // MARK: Live data

    /// Starts or stops the live stream. A start is owed a stop until one gets through, across
    /// links and launches: the firmware keeps streaming after a disconnect.
    func setLive(_ on: Bool) async {
        if on {
            defaults.set(true, forKey: Self.liveStopOwedKey)
            liveOn = true
            if let frames = try? await transport.perform(.x5Live(true), until: .single) {
                frames.forEach(handleLive)
            }
        } else {
            liveOn = false
            if (try? await transport.perform(.x5Live(false), until: .single)) != nil {
                defaults.set(false, forKey: Self.liveStopOwedKey)
            }
        }
    }

    // MARK: Measurements

    /// A spot reading. Heart rate and SpO₂ run the ring's own measurement and read its live
    /// stream every second; temperature is a single read.
    func measure(_ type: RingMeasurementType, seconds: Int = 30) async throws -> Double? {
        if type == .temperature {
            let value = try await reply(.x5SkinTemp)
            skinTemp = X5Decode.skinTemp(value)
            measurement = X5Measurement(type: type, startedAt: now(), seconds: 0, latest: skinTemp, result: skinTemp,
                                        failed: skinTemp == nil ? "not on a finger" : nil, isActive: false)
            return skinTemp
        }
        let kind: UInt8
        switch type {
        case .heartRate: kind = 2
        case .spo2: kind = 3
        default: throw RingError.unsupported(type.name)
        }
        if measurement?.isActive == true { throw RingError.busy("a measurement is running") }
        measurementValues = []
        measurement = X5Measurement(type: type, startedAt: now(), seconds: seconds, isActive: true)
        do {
            _ = try await transport.perform(.x5Measure(kind, start: true, seconds: seconds), until: .single)
        } catch {
            measurement?.isActive = false
            measurement?.failed = error.localizedDescription
            throw error
        }
        let liveWasOn = liveOn
        if !liveWasOn { await setLive(true) }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds) + 1)
        while Date() < deadline, measurement?.isActive == true {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        _ = try? await transport.perform(.x5Measure(kind, start: false, seconds: 0), until: .single)
        if !liveWasOn, !holdsLive { await setLive(false) }
        let result = Self.settle(measurementValues)
        measurement?.isActive = false
        measurement?.result = result
        if result == nil { measurement?.failed = "no reading — is the ring on a finger?" }
        return result
    }

    func stopMeasurement() async {
        guard let m = measurement, m.isActive else { return }
        measurement?.isActive = false
        measurement?.failed = "stopped"
        let kind: UInt8 = m.type == .spo2 ? 3 : 2
        _ = try? await transport.perform(.x5Measure(kind, start: false, seconds: 0), until: .single)
    }

    /// The median of the last five readings: the stream settles over the measurement.
    static func settle(_ values: [Double]) -> Double? {
        let tail = values.suffix(5).sorted()
        guard !tail.isEmpty else { return nil }
        return tail[tail.count / 2]
    }

    // MARK: Settings and maintenance

    func setProfile(_ p: X5Profile) async throws {
        _ = try await transport.perform(.x5SetProfile(male: p.male, age: p.age, heightCm: p.heightCm, weightKg: p.weightKg,
                                                      strideCm: p.strideCm), until: .single)
        profile = X5Profile(male: p.male, age: p.age, heightCm: p.heightCm, weightKg: p.weightKg,
                            strideCm: p.strideCm, mac: profile?.mac ?? p.mac)
    }

    func setGoal(_ steps: Int) async throws {
        _ = try await transport.perform(.x5SetGoal(steps), until: .single)
        goal = steps
    }

    func restart() async throws { _ = try await transport.perform(.x5Restart, until: .single) }

    /// Off until it is next charged.
    func powerOff() async throws { _ = try await transport.perform(.x5Power(off: true), until: .single) }

    /// Deletes every history store on the ring. Only from an explicit, confirmed user action.
    func clearHistory() async throws {
        for kind in X5HistoryKind.allCases where kind != .manualSpO2 || features.contains(.manualSpO2) {
            _ = try? await transport.perform(.x5HistoryDelete(kind), until: .single)
        }
    }

    /// Best effort: the ring may not know this command.
    func unbind() async { _ = try? await transport.perform(.x5Unbind, until: .single) }

    /// `action` 1 start, 2 pause, 3 resume, 4 end, 5 status.
    func workout(_ action: UInt8, sport: X5Sport) async throws -> (ok: Bool, start: Date?) {
        let p = try await reply(.x5Workout(action, sport: sport))
        let decoded = X5Decode.workoutReply(p, calendar: calendar)
        return (decoded.ok, decoded.start)
    }

    // MARK: Probing

    private struct ProbeRecord: Codable {
        var firmware: String
        var features: Set<X5Feature>
    }

    private func probeKey(_ deviceID: String) -> String { "jc.x5.probe.\(deviceID)" }

    private func storedProbe(_ deviceID: String) -> ProbeRecord? {
        defaults.data(forKey: probeKey(deviceID)).flatMap { try? JSONDecoder().decode(ProbeRecord.self, from: $0) }
    }

    private func needsProbe(deviceID: String) -> Bool {
        guard let version = firmware?.version else { return storedProbe(deviceID) == nil }
        return storedProbe(deviceID)?.firmware != version
    }

    private func loadProbe(deviceID: String) {
        if let stored = storedProbe(deviceID) { features = stored.features }
    }

    /// Asks the ring for the features its sheet doesn't promise. Read-only commands only.
    func probe(deviceID: String) async {
        var found: Set<X5Feature> = []
        if let p = try? await reply(.x5GetGoal), let g = X5Decode.goal(p) {
            found.insert(.stepGoal)
            goal = g
        }
        if (try? await transport.perform(.x5History(.manualSpO2, after: nil, calendar: calendar),
                                         until: .packets(X5Frames.isEnd))) != nil {
            found.insert(.manualSpO2)
        }
        if (try? await transport.perform(.x5PPG(1), until: .single)) != nil {
            found.insert(.ppg)
            _ = try? await transport.perform(.x5PPG(5), until: .single)
        }
        features = found
        let record = ProbeRecord(firmware: firmware?.version ?? "", features: found)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: probeKey(deviceID)) }
        log.note("X5 features", found.isEmpty ? "none beyond the sheet" : found.map(\.label).sorted().joined(separator: ", "))
    }

    // MARK: Pushed frames

    private func handle(_ inbound: RingInbound) {
        guard !inbound.isError else { return }
        switch inbound.cmd {
        case X5Op.key:
            guard let gesture = X5Decode.gesture(inbound.payload) else { return }
            let at = now()
            if let last = lastGesture, last.gesture == gesture, at.timeIntervalSince(last.date) < Self.gestureEchoWindow {
                return
            }
            lastGesture = X5GestureEvent(gesture: gesture, date: at)
            onGesture?(gesture)
        case X5Op.hid where X5Decode.isTouchTimeout(inbound.payload):
            touchAsleep = true
            log.note("X5 touch asleep", "timed out")
            guard awakePolicy == .always, wantedHID().enabled else { return }
            let at = now()
            if let last = lastRearm, at.timeIntervalSince(last) < Self.rearmInterval { return }
            lastRearm = at
            Task { await self.applyHID() }
        case X5Op.live:
            handleLive(inbound)
        case X5Op.workoutTick:
            if let tick = X5Decode.tick(inbound.payload) { onWorkoutTick?(tick) }
        default:
            break
        }
    }

    private func handleLive(_ inbound: RingInbound) {
        guard inbound.cmd == X5Op.live, let sample = X5Decode.live(inbound.payload) else { return }
        live = sample
        guard let m = measurement, m.isActive else { return }
        let value: Double
        switch m.type {
        case .heartRate: value = Double(sample.heartRate)
        case .spo2: value = Double(sample.spo2)
        default: return
        }
        let plausible = m.type == .heartRate ? X5DayMapper.plausibleHeartRate : X5DayMapper.plausibleSpO2
        guard plausible.contains(value) else { return }
        measurementValues.append(value)
        measurement?.latest = value
    }
}

/// Names X5 frames for the decoded log.
enum X5LogDecoder {
    static func describe(_ frame: RingFrame) -> (title: String, detail: String) {
        let p = frame.payload
        let dir = frame.outbound ? "→" : "←"
        let title: String
        var detail = frame.note
        switch frame.cmd {
        case X5Op.setTime: title = "Set time"
        case X5Op.getTime: title = "Time"
        case X5Op.setProfile: title = "Set profile"
        case X5Op.getProfile: title = "Profile"
        case X5Op.battery:
            title = "Battery"
            if !frame.outbound, let b = X5Decode.battery(p) { detail = "\(b.battery.percent)%\(b.battery.charging ? ", charging" : "")" }
        case X5Op.mac: title = "MAC address"
        case X5Op.firmware: title = "Firmware"
        case X5Op.power: title = "Power"
        case X5Op.restart: title = "Restart"
        case X5Op.live:
            title = frame.outbound ? (p.first == 1 ? "Live data on" : "Live data off") : "Live data"
            if !frame.outbound, let l = X5Decode.live(p) { detail = "\(l.steps) steps, HR \(l.heartRate), SpO₂ \(l.spo2)" }
        case X5Op.skinTemp: title = "Skin temperature"
        case X5Op.measure: title = p.first == 0x80 ? "Measurement status" : "Spot measurement"
        case X5Op.setMonitoring: title = "Set monitoring"
        case X5Op.getMonitoring: title = "Monitoring"
        case X5Op.workout: title = "Workout"
        case X5Op.workoutTick: title = "Workout tick"
        case X5Op.hid:
            title = X5Decode.isTouchTimeout(p) && !frame.outbound ? "Touch timed out" : "Touch settings"
        case X5Op.key:
            title = "Gesture"
            if let g = X5Decode.gesture(p) { detail = g.input.label }
        case X5Op.setGoal: title = "Set step goal"
        case X5Op.getGoal: title = "Step goal"
        case X5Op.ppg: title = "PPG"
        case X5Op.clearAll: title = "Clear history"
        case X5Op.unbind: title = "Unbind"
        default:
            if let kind = X5HistoryKind(rawValue: frame.cmd) {
                title = "History \(kind)"
                if p == [0xFF] { detail = "end" }
            } else {
                title = String(format: "0x%02X", frame.cmd)
            }
        }
        return ("\(dir) \(title)\(frame.isError ? " (failed)" : "")", detail)
    }
}
