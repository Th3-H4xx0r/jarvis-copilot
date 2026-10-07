import Foundation

// Who decides when the band measures. Its own automatic measuring (the `B8` switches) runs all
// day and costs it most of its battery; managed by the phone, those switches are off and the
// phone — holding the link — asks for each reading on the intervals set here. The band's
// pulse-rate (PPG) and HRV switches stay its own: they carry sleep and overnight HRV, which the
// phone can't ask for.

enum BandMeasureControl: String, Codable {
    case band, phone
}

struct BandMeasurePlan: Codable, Equatable {
    var control: BandMeasureControl = .band
    /// Minutes between readings, by `BandMeasure.name`; 0 is never.
    var intervals: [String: Int] = BandMeasurePlan.defaultIntervals
    /// How the band had its own switches before the phone took over, put back on the way out.
    var bandSwitches: [String: Bool]? = nil
    var nightOxygen: Bool? = nil
    var keepAliveBefore: Bool? = nil

    /// What the phone can ask for (the optical readings; ECG and body composition need a finger).
    static let types: [BandMeasure] = [.heartRate, .bloodOxygen, .bloodPressure, .stress, .temperature,
                                       .bloodGlucose, .bloodComponent]
    static let defaultIntervals: [String: Int] = [
        "heart_rate": 30, "spo2": 60, "blood_pressure": 120, "stress": 60, "temperature": 60,
        "blood_glucose": 60, "blood_component": 0,
    ]
    static let choices = [0, 15, 30, 60, 120, 240, 480]
    /// The band's switches the phone turns off while it manages measuring.
    static let autoSwitches = ["auto_heart_rate", "auto_blood_pressure", "auto_temperature", "auto_blood_glucose",
                               "auto_stress", "auto_blood_component"]

    func interval(_ m: BandMeasure) -> Int { intervals[m.name] ?? 0 }

    static func label(_ minutes: Int) -> String {
        if minutes == 0 { return "Off" }
        return minutes < 60 ? "Every \(minutes) min" : minutes == 60 ? "Every hour" : "Every \(minutes / 60) h"
    }
}

/// Runs the plan: every half minute, the most overdue reading, one at a time, while the band is
/// connected and free (not measuring, no workout under way).
@MainActor
final class BandMeasureScheduler: ObservableObject {
    @Published private(set) var plan: BandMeasurePlan
    /// When each type was last asked for.
    @Published private(set) var lastRuns: [String: Date]
    @Published private(set) var applying = false

    private weak var manager: BandManager?
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    var now: () -> Date = Date.init
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

    /// The reading most overdue at `date`, if any.
    func due(at date: Date) -> BandMeasure? {
        guard plan.control == .phone else { return nil }
        let overdue = BandMeasurePlan.types.compactMap { m -> (BandMeasure, TimeInterval)? in
            let minutes = plan.interval(m)
            guard minutes > 0 else { return nil }
            let next = (lastRuns[m.name] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60))
            return next <= date ? (m, date.timeIntervalSince(next)) : nil
        }
        return overdue.max { $0.1 < $1.1 }?.0
    }

    /// When `m` is next asked for (nil: never).
    func next(_ m: BandMeasure) -> Date? {
        let minutes = plan.interval(m)
        guard plan.control == .phone, minutes > 0 else { return nil }
        return max(now(), (lastRuns[m.name] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func runDue() async {
        guard let manager, plan.control == .phone, manager.state == .ready, manager.session.measuring == nil,
              !manager.holdsLinkForWorkout, let type = due(at: now()) else { return }
        mark(type)
        // A type this band doesn't have waits its interval like any other, quietly.
        guard manager.session.supports(type.name) else { return }
        _ = try? await manager.session.measure(type)
    }

    func setInterval(_ minutes: Int, for m: BandMeasure) {
        plan.intervals[m.name] = minutes
        save()
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
                for name in BandMeasurePlan.autoSwitches { if let on = settings.isOn(name) { was[name] = on } }
                next.bandSwitches = was
                let off = was.mapValues { _ in false as Any }
                if let quiet = BandSettings(json: off, base: settings), quiet != settings { try await session.writeSettings(quiet) }
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
            if let was = next.bandSwitches, let settings = session.settings,
               let restored = BandSettings(json: was.mapValues { $0 as Any }, base: settings), restored != settings {
                try await session.writeSettings(restored)
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
        }
        next.control = control
        plan = next
        save()
    }

    private func mark(_ m: BandMeasure) {
        lastRuns[m.name] = now()
        defaults.setValue(lastRuns.mapValues { $0.timeIntervalSince1970 }, forKey: Self.lastKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plan) { defaults.setValue(data, forKey: Self.planKey) }
    }

    /// Tests: a plan without the band.
    func seedForTests(_ plan: BandMeasurePlan, lastRuns: [String: Date] = [:]) {
        self.plan = plan
        self.lastRuns = lastRuns
    }
}
