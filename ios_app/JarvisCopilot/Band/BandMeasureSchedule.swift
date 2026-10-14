import Foundation

// Who decides when the band measures. Its own automatic measuring (the `B8` switches) runs all
// day and costs it most of its battery; managed by the phone, those switches are off and the
// phone — holding the link — asks for each reading on the intervals set here. The band's
// pulse-rate (PPG) and HRV switches run its sensor every minute (a heart rate each minute, an
// HRV each 5-minute record), so the phone keeps them for the overnight window — precise sleep
// and overnight HRV, which it can't ask for — and by day turns HRV on only for one record on
// its interval: HRV has no command of its own.

enum BandMeasureControl: String, Codable {
    case band, phone
}

struct BandMeasurePlan: Codable, Equatable {
    var control: BandMeasureControl = .band
    /// Minutes between readings, by `BandMeasure.name` (and `hrv`); 0 is never.
    var intervals: [String: Int] = BandMeasurePlan.defaultIntervals
    /// The band's own pulse and HRV measuring overnight, for sleep; minutes after midnight.
    var nightTracking = true
    var nightStart = 21 * 60
    var nightEnd = 11 * 60
    /// How the band had its own switches before the phone took over, put back on the way out.
    var bandSwitches: [String: Bool]? = nil
    var nightOxygen: Bool? = nil
    var keepAliveBefore: Bool? = nil

    init() {}

    /// A plan saved before a field existed keeps what it has and takes the default for the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BandMeasurePlan()
        control = try c.decodeIfPresent(BandMeasureControl.self, forKey: .control) ?? d.control
        intervals = try c.decodeIfPresent([String: Int].self, forKey: .intervals) ?? d.intervals
        nightTracking = try c.decodeIfPresent(Bool.self, forKey: .nightTracking) ?? d.nightTracking
        nightStart = try c.decodeIfPresent(Int.self, forKey: .nightStart) ?? d.nightStart
        nightEnd = try c.decodeIfPresent(Int.self, forKey: .nightEnd) ?? d.nightEnd
        bandSwitches = try c.decodeIfPresent([String: Bool].self, forKey: .bandSwitches)
        nightOxygen = try c.decodeIfPresent(Bool.self, forKey: .nightOxygen)
        keepAliveBefore = try c.decodeIfPresent(Bool.self, forKey: .keepAliveBefore)
    }

    /// What the phone can ask for (the optical readings; ECG and body composition need a finger).
    static let types: [BandMeasure] = [.heartRate, .bloodOxygen, .bloodPressure, .stress, .temperature,
                                       .bloodGlucose, .bloodComponent]
    static let defaultIntervals: [String: Int] = [
        "heart_rate": 30, "spo2": 60, "blood_pressure": 120, "stress": 60, "temperature": 60,
        "blood_glucose": 60, "blood_component": 0, BandMeasurePlan.hrv: 60,
    ]
    /// The interval key for HRV, which the phone gets by turning the band's HRV switch on.
    static let hrv = "hrv"
    static let choices = [0, 15, 30, 60, 120, 240, 480]
    /// The band's switches the phone turns off while it manages measuring.
    static let autoSwitches = ["auto_heart_rate", "auto_blood_pressure", "auto_temperature", "auto_blood_glucose",
                               "auto_stress", "auto_blood_component"]
    /// The band's every-minute sensing: on through the night window, off by day.
    static let sensingSwitches = ["auto_ppg", "auto_hrv"]
    /// What a daytime HRV record needs on: HRV alone records nothing (his E910, 2026-10-14 — PPG
    /// off, HRV on: no heart rate from that minute and no HRV in the next record).
    static let hrvSwitches = ["auto_ppg", "auto_hrv"]

    func interval(_ m: BandMeasure) -> Int { interval(m.name) }
    /// A type missing from `intervals` is off; HRV, which plans saved before it lack, takes its default.
    func interval(_ name: String) -> Int {
        intervals[name] ?? (name == Self.hrv ? Self.defaultIntervals[name] ?? 0 : 0)
    }

    /// Whether `date` falls in the night window (it may cross midnight).
    func inNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard nightTracking, nightStart != nightEnd else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return nightStart < nightEnd ? (nightStart..<nightEnd).contains(m) : (m >= nightStart || m < nightEnd)
    }

    static func label(_ minutes: Int) -> String {
        if minutes == 0 { return "Off" }
        return minutes < 60 ? "Every \(minutes) min" : minutes == 60 ? "Every hour" : "Every \(minutes / 60) h"
    }
}

/// Runs the plan: every half minute, the band's pulse/HRV switches as the hour wants them, then
/// the most overdue reading, one at a time, while the band is connected and free (not measuring,
/// no workout under way).
@MainActor
final class BandMeasureScheduler: ObservableObject {
    @Published private(set) var plan: BandMeasurePlan
    /// When each type's current interval started (what its next reading counts from).
    @Published private(set) var lastRuns: [String: Date]
    /// Until when the band's HRV is on for a daytime record.
    @Published private(set) var hrvUntil: Date?
    /// A type whose reading failed ("not worn", busy, no value) this interval, and when: it is
    /// tried once more after `retryAfter`, then waits for its next interval.
    private var failures: [String: Date] = [:]
    /// When the last scheduled reading ended: the next waits `settle` so the sensor settles (back
    /// to back, the band answered "not worn" while worn).
    private var lastEnded: Date?
    var retryAfter: TimeInterval = 180
    var settle: TimeInterval = 60
    /// After the 5-minute record HRV is on for closes, how long before it goes off again (the
    /// band writes the record a little after its slot ends).
    var hrvTail: TimeInterval = 45
    @Published private(set) var applying = false

    private weak var manager: BandManager?
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    var now: () -> Date = Date.init
    var calendar = Calendar.current
    var tick: TimeInterval = 30

    static let planKey = "band.measurePlan"
    static let lastKey = "band.measureLast"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plan = defaults.data(forKey: Self.planKey).flatMap { try? JSONDecoder().decode(BandMeasurePlan.self, from: $0) }
            ?? BandMeasurePlan()
        let stamps = defaults.dictionary(forKey: Self.lastKey) as? [String: Double] ?? [:]
        lastRuns = stamps.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func attach(_ manager: BandManager) {
        self.manager = manager
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.tick ?? 30))
                await self?.runDue()
            }
        }
    }

    /// The reading most overdue at `date`, if any (one that just failed waits its retry).
    func due(at date: Date) -> BandMeasure? {
        guard plan.control == .phone else { return nil }
        if let lastEnded, date.timeIntervalSince(lastEnded) < settle { return nil }
        let overdue = BandMeasurePlan.types.compactMap { m -> (BandMeasure, TimeInterval)? in
            let minutes = plan.interval(m)
            guard minutes > 0 else { return nil }
            let next = (lastRuns[m.name] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60))
            guard next <= date else { return nil }
            if let failedAt = failures[m.name], date.timeIntervalSince(failedAt) < retryAfter { return nil }
            return (m, date.timeIntervalSince(next))
        }
        return overdue.max { $0.1 < $1.1 }?.0
    }

    /// When `m` is next asked for (nil: never).
    func next(_ m: BandMeasure) -> Date? {
        let minutes = plan.interval(m)
        guard plan.control == .phone, minutes > 0 else { return nil }
        return max(now(), (lastRuns[m.name] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// Whether a daytime HRV record is due at `date` (overnight the band's HRV is on anyway).
    func hrvDue(at date: Date) -> Bool {
        let minutes = plan.interval(BandMeasurePlan.hrv)
        guard plan.control == .phone, minutes > 0, !plan.inNight(date, calendar: calendar),
              hrvUntil.map({ date >= $0 }) ?? true else { return false }
        return (lastRuns[BandMeasurePlan.hrv] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60)) <= date
    }

    /// Starts a daytime HRV record when one is due: the band's HRV on through the next whole
    /// 5-minute record (its slots start on the clock's fives), then off.
    func startHrvIfDue() {
        let date = now()
        guard hrvDue(at: date) else { return }
        let minute = calendar.dateComponents([.minute, .second], from: date)
        let intoSlot = TimeInterval(((minute.minute ?? 0) % 5) * 60 + (minute.second ?? 0))
        hrvUntil = date.addingTimeInterval(300 - intoSlot + 300 + hrvTail)
        mark(BandMeasurePlan.hrv)
    }

    /// The band's pulse and HRV switches as they should be at `date`: on overnight, HRV's on
    /// through a daytime record, off otherwise.
    func sensing(at date: Date) -> [String: Bool] {
        Self.sensing(plan, hrvOn: hrvUntil.map { date < $0 } ?? false, at: date, calendar: calendar)
    }

    static func sensing(_ plan: BandMeasurePlan, hrvOn: Bool, at date: Date, calendar: Calendar) -> [String: Bool] {
        let night = plan.inNight(date, calendar: calendar)
        var out: [String: Bool] = [:]
        for name in BandMeasurePlan.sensingSwitches {
            out[name] = night || (hrvOn && BandMeasurePlan.hrvSwitches.contains(name))
        }
        return out
    }

    /// Writes the sensing switches when the band's differ from `sensing(at:)`.
    func reconcile() async {
        guard let manager, plan.control == .phone, !applying, manager.session.measuring == nil,
              !manager.holdsLinkForWorkout, let settings = manager.session.settings else { return }
        var next = settings
        for (name, on) in sensing(at: now()) where settings.isOn(name).map({ $0 != on }) ?? false {
            next.set(name, on)
        }
        guard next != settings else { return }
        if manager.state != .ready {
            guard await manager.ensureConnected() else { return }
        }
        try? await manager.session.writeSettings(next)
    }

    func runDue() async {
        guard let manager, plan.control == .phone else { return }
        startHrvIfDue()
        await reconcile()
        guard manager.session.measuring == nil, !manager.holdsLinkForWorkout, let type = due(at: now()) else { return }
        // A due reading brings the band back if its link dropped.
        if manager.state != .ready {
            guard await manager.ensureConnected() else { return }
        }
        // A type this band doesn't have waits its interval like any other, quietly.
        guard manager.session.supports(type.name) else { return mark(type.name) }
        let reading = try? await manager.session.measure(type)
        finished(type, done: reading?.status == .done)
    }

    /// A scheduled reading ended: a value starts its next interval; a failure is tried once more,
    /// and a second one waits for the next interval like a value would.
    func finished(_ type: BandMeasure, done: Bool) {
        lastEnded = now()
        if done || failures[type.name] != nil {
            failures[type.name] = nil
            mark(type.name)
        } else {
            failures[type.name] = now()
        }
    }

    func setInterval(_ minutes: Int, for m: BandMeasure) { setInterval(minutes, named: m.name) }

    func setInterval(_ minutes: Int, named name: String) {
        plan.intervals[name] = minutes
        save()
        if name == BandMeasurePlan.hrv, minutes == 0, hrvUntil != nil {
            hrvUntil = nil
            Task { await reconcile() }
        }
    }

    /// The overnight window the band's own pulse and HRV measuring keeps (minutes after midnight).
    func setNight(tracking: Bool, start: Int, end: Int) {
        plan.nightTracking = tracking
        plan.nightStart = max(0, min(1439, start))
        plan.nightEnd = max(0, min(1439, end))
        save()
        Task { await reconcile() }
    }

    /// Hands measuring to the phone (the band's switches off, the link held) or back to the band
    /// (its switches and Keep Alive as they were). Needs the band connected to change its switches.
    func setControl(_ control: BandMeasureControl) async throws {
        guard control != plan.control, let manager else { return }
        applying = true
        defer { applying = false }
        guard await manager.ensureConnected() else { throw BandError.notConnected }
        let session = manager.session
        var next = plan
        if control == .phone {
            if let settings = session.settings {
                var was: [String: Bool] = [:]
                for name in BandMeasurePlan.autoSwitches + BandMeasurePlan.sensingSwitches {
                    if let on = settings.isOn(name) { was[name] = on }
                }
                next.bandSwitches = was
                var quiet = settings
                for name in BandMeasurePlan.autoSwitches { quiet.set(name, false) }
                for (name, on) in Self.sensing(next, hrvOn: false, at: now(), calendar: calendar) { quiet.set(name, on) }
                if quiet != settings { try await session.writeSettings(quiet) }
            }
            if let oxygen = session.oxygenSchedule {
                next.nightOxygen = oxygen.enabled
                if oxygen.enabled {
                    try await session.setBloodOxygenAuto(enabled: false, start: (oxygen.startHour, oxygen.startMinute),
                                                         end: (oxygen.endHour, oxygen.endMinute))
                }
            }
            next.keepAliveBefore = WearableKeepAlive.isOn(WearableKeepAlive.band)
            _ = WearablesHub.shared.setKeepAlive(true, for: WearableKeepAlive.band)
        } else {
            if let settings = session.settings {
                var was = next.bandSwitches ?? [:]
                // Taken over before the phone ran these, they were never changed: the band's own (on).
                for name in BandMeasurePlan.sensingSwitches where was[name] == nil { was[name] = true }
                var restored = settings
                for (name, on) in was { restored.set(name, on) }
                if restored != settings { try await session.writeSettings(restored) }
            }
            if next.nightOxygen == true {
                let o = session.oxygenSchedule
                try await session.setBloodOxygenAuto(enabled: true, start: (o?.startHour ?? 22, o?.startMinute ?? 0),
                                                     end: (o?.endHour ?? 7, o?.endMinute ?? 0))
            }
            if next.keepAliveBefore == false { _ = WearablesHub.shared.setKeepAlive(false, for: WearableKeepAlive.band) }
            next.bandSwitches = nil
            next.nightOxygen = nil
            next.keepAliveBefore = nil
            hrvUntil = nil
        }
        next.control = control
        plan = next
        save()
    }

    /// Starts `name`'s next interval from when this one was due, so the cadence holds (counted
    /// from the reading's end, each one drifted by its length and the tick). A reading more than
    /// an interval late starts afresh.
    private func mark(_ name: String) {
        let at = now()
        let length = TimeInterval(plan.interval(name) * 60)
        if let last = lastRuns[name], length > 0 {
            let due = last.addingTimeInterval(length)
            lastRuns[name] = due <= at && at.timeIntervalSince(due) < length ? due : at
        } else {
            lastRuns[name] = at
        }
        defaults.setValue(lastRuns.mapValues { $0.timeIntervalSince1970 }, forKey: Self.lastKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plan) { defaults.setValue(data, forKey: Self.planKey) }
    }

    /// Tests: a plan without the band.
    func seedForTests(_ plan: BandMeasurePlan, lastRuns: [String: Date] = [:]) {
        self.plan = plan
        self.lastRuns = lastRuns
        hrvUntil = nil
        failures = [:]
    }
}
