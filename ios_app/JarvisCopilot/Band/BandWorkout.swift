import Combine
import Foundation

/// The band as a workout wearable. Its app sport mode (start/pause/resume/stop) has the band
/// record the session; it reports the session only when asked (`DA 02`, polled every couple
/// of seconds) plus the odd unprompted heart-rate report. So this makes the per-second ticks:
/// the phone keeps the clock (pauses are the buttons'), the band's status gives heart rate,
/// distance and calories, and its step counter, counted from the start, gives steps.
///
/// The band is told which sport it is (its `ESportType`): with none it runs an outdoor run,
/// which pauses itself when you stand still — between sets — and then drops the session, so
/// heart rate froze on its last value. A session the band paused or ended on its own is
/// resumed or started again: only Jarvis's pause pauses a workout.
@MainActor
final class BandWorkoutWearable: WorkoutWearable {
    private let session: BandSession
    private let connect: () async -> Bool
    private let drop: () -> Void
    private let release: () -> Void
    private let device: () -> String?
    private let clock: () -> Date
    /// How often the band's workout status and steps are read during a workout.
    var statusInterval: TimeInterval = 2
    var stepInterval: TimeInterval = 5

    private var sportID = RingSport.otherID
    /// The band's sport type for this workout.
    private(set) var bandType = 0
    /// When the band last said its session was running (or sent a heart rate on its own):
    /// older than `liveWindow`, its heart rate is stale and isn't shown.
    private var liveAt: Date?
    var liveWindow: TimeInterval = 15
    /// The band's own pause / end, answered at most this often.
    var nudgeInterval: TimeInterval = 8
    private var lastNudge: Date?
    /// Distance and energy from sessions the band dropped and was started again on.
    private var carriedMeters = 0
    private var carriedCalories = 0
    private var startedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var baseline: BandSteps?
    private var latestSteps: BandSteps?
    private var status: BandSportStatus?
    private var statusPoll: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var stepPoll: Task<Void, Never>?

    init(session: BandSession, connect: @escaping () async -> Bool, disconnect: @escaping () -> Void = {},
         release: @escaping () -> Void = {}, deviceID: @escaping () -> String? = { nil },
         state: AnyPublisher<ConnectionState, Never>? = nil, clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.connect = connect
        self.drop = disconnect
        self.release = release
        self.device = deviceID
        self.clock = clock
        super.init(kind: WearableKeepAlive.band)
        mirror(state: state, battery: state == nil ? nil : session.$battery.eraseToAnyPublisher())
        session.onSportStatus = { [weak self] report in self?.merge(report) }
    }

    override var deviceID: String? { device() }
    override var fallbackName: String { BandDevice.fallbackName }
    /// Ticks come from the phone's clock: pauses are the buttons'.
    override var pauseFromTicks: Bool { false }

    override func ensureConnected() async -> Bool { await connect() }
    override func disconnect() { drop() }
    override func released() { release() }

    @discardableResult
    override func send(_ command: RingSportCommand, sport: Int) async -> Bool {
        switch command {
        case .start:
            var type = Self.bandType(for: sport)
            var accepted = await session.sport(.start, type: type)
            if !accepted {
                // Busy (an app sport nobody is tracking) or a lost ack: end it, start this one.
                _ = await session.sport(.stop, type: type)
                accepted = await session.sport(.start, type: type)
            }
            if !accepted, type != Self.fitness {
                // A type this firmware doesn't have: general fitness, which every band has.
                type = Self.fitness
                accepted = await session.sport(.start, type: type)
            }
            guard accepted else { return false }
            sportID = sport
            bandType = type
            startedAt = clock()
            pausedTotal = 0
            pausedAt = nil
            status = nil
            liveAt = nil
            lastNudge = nil
            carriedMeters = 0
            carriedCalories = 0
            baseline = await session.readSteps()
            latestSteps = baseline
            startTicking()
            return true
        case .pause:
            // Stamped at the press, not when the band gets round to answering.
            if pausedAt == nil { pausedAt = clock() }
            _ = await session.sport(.pause, type: bandType)
            return true
        case .resume:
            if let pausedAt { pausedTotal += max(0, clock().timeIntervalSince(pausedAt)) }
            pausedAt = nil
            _ = await session.sport(.resume, type: bandType)
            return true
        case .stop:
            _ = await session.sport(.stop, type: bandType)
            finish()
            return true
        case .query:
            return true
        }
    }

    /// The band's find buzz, stopped after a moment.
    override var canSignal: Bool { session.supports("find") }
    override var signalName: String { "Buzzes" }

    override func signal() async {
        guard (try? await session.find(true)) != nil else { return }
        try? await Task.sleep(for: .seconds(1.5))
        try? await session.find(false)
    }

    override func todayActivity() async -> (steps: Int, meters: Int)? {
        guard let steps = await session.readSteps() else { return nil }
        return (steps.steps, steps.distanceMeters ?? 0)
    }

    // MARK: Ticks

    private var elapsed: Int {
        guard let startedAt else { return 0 }
        let paused = pausedTotal + (pausedAt.map { max(0, clock().timeIntervalSince($0)) } ?? 0)
        return max(0, Int(clock().timeIntervalSince(startedAt) - paused))
    }

    private func tick(state: RingSportTick.State) -> RingSportTick {
        let now = latestSteps, base = baseline
        let steps = max(0, (now?.steps ?? 0) - (base?.steps ?? 0))
        let counted = max(0, (now?.distanceMeters ?? 0) - (base?.distanceMeters ?? 0))
        let meters = status?.distanceMeters.map { $0 + carriedMeters } ?? counted
        // The band counts small calories.
        let kcal = Double((status?.calories ?? 0) + carriedCalories) / 1000
        // Only a heart rate the band is still measuring: a dropped session keeps its last one.
        let live = liveAt.map { clock().timeIntervalSince($0) <= liveWindow } ?? false
        let hr = live ? status?.heartRate.flatMap { (30...240).contains($0) ? $0 : nil } : nil
        return RingSportTick(sport: sportID, state: state, elapsed: elapsed, heartRate: hr, steps: steps,
                             distanceMeters: meters, kilocalories: kcal)
    }

    private func startTicking() {
        ticker?.cancel()
        stepPoll?.cancel()
        statusPoll?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.onTick?(self.tick(state: self.pausedAt == nil ? .running : .paused))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.statusInterval))
                guard !Task.isCancelled else { return }
                if let report = await self.session.sportStatus(type: self.bandType) { self.merge(report) }
            }
        }
        stepPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.stepInterval))
                guard !Task.isCancelled else { return }
                if let steps = await self.session.readSteps() { self.latestSteps = steps }
            }
        }
    }

    /// A status poll or an unprompted report: keep each field the newest one carries.
    private func merge(_ report: BandSportStatus) {
        guard startedAt != nil else { return }
        var next = status ?? report
        if let hr = report.heartRate { next.heartRate = hr }
        if let d = report.distanceMeters { next.distanceMeters = d }
        if let c = report.calories { next.calories = c }
        if let e = report.elapsedSeconds { next.elapsedSeconds = e }
        if let r = report.runState { next.runState = r }
        status = next
        // A poll that says the session runs, or the band's own report (sent only while it does).
        if report.runState == .exercising || (report.report && report.heartRate != nil) { liveAt = clock() }
        keepRunning(report)
    }

    /// The band paused or ended the session by itself while the workout runs: resume it, or
    /// start it again (what it had counted is carried over). Not while it's charging or full.
    private func keepRunning(_ report: BandSportStatus) {
        guard startedAt != nil, pausedAt == nil, !report.report, let state = report.runState,
              state == .paused || state == .notStarted,
              report.deviceState == nil || report.deviceState == .normal || report.deviceState == .lowBattery else { return }
        if let lastNudge, clock().timeIntervalSince(lastNudge) < nudgeInterval { return }
        lastNudge = clock()
        let op: BandSportOp = state == .paused ? .resume : .start
        if op == .start {
            carriedMeters += status?.distanceMeters ?? 0
            carriedCalories += status?.calories ?? 0
            status?.distanceMeters = nil
            status?.calories = nil
        }
        let type = bandType
        Task { [weak self] in
            guard let self else { return }
            if !(await self.session.sport(op, type: type)), op == .resume {
                _ = await self.session.sport(.start, type: type)
            }
        }
    }

    // MARK: Sport types

    static let fitness = 24

    /// The band's sport (the Android SDK's `ESportType`, the iOS SDK's `VPDeviceRuningMode`)
    /// for each of the app's.
    static func bandType(for sport: Int) -> Int {
        switch sport {
        case 7: return 1            // run → outdoor run
        case 4: return 2            // walk → outdoor walk
        case 40: return 3           // treadmill → indoor run
        case 41: return 4           // indoor walk
        case 8: return 5            // hike
        case 80: return 6           // stair climber → stepper
        case 9: return 7            // cycle → outdoor cycle
        case 24: return 8           // indoor cycle → stationary bike
        case 26: return 9           // elliptical
        case 27: return 10          // rowing machine
        case 6: return 12           // swim
        case 5: return 15           // jump rope
        case 22: return 16          // yoga
        case 31: return 18          // basketball
        case 32: return 20          // football
        case 21: return 21          // badminton
        case 29: return 22          // tennis
        case RingSport.strengthID: return 25   // strength → weightlifting
        case 35: return 31          // dance
        case 89: return 32          // interval training → HIIT
        case 20: return 33          // climbing → rock climbing
        case 30: return 53          // golf
        case 42: return 64          // trail run
        default: return fitness     // pilates, other…
        }
    }

    private func finish() {
        ticker?.cancel()
        stepPoll?.cancel()
        statusPoll?.cancel()
        ticker = nil
        stepPoll = nil
        statusPoll = nil
        guard startedAt != nil else { return }
        let last = tick(state: .ended)
        startedAt = nil
        onTick?(last)
    }
}
