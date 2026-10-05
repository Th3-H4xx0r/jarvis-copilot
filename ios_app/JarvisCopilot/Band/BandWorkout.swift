import Combine
import Foundation

/// The band as a workout wearable. Its app sport mode (start/pause/resume/stop) has the band
/// record the session; it reports the session only when asked (`DA 02`, polled every couple
/// of seconds) plus the odd unprompted heart-rate report. So this makes the per-second ticks:
/// the phone keeps the clock (pauses are the buttons'), the band's status gives heart rate,
/// distance and calories, and its step counter, counted from the start, gives steps.
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
            var accepted = await session.sport(.start)
            if !accepted {
                // Busy (an app sport nobody is tracking) or a lost ack: end it, start this one.
                _ = await session.sport(.stop)
                accepted = await session.sport(.start)
            }
            guard accepted else { return false }
            sportID = sport
            startedAt = clock()
            pausedTotal = 0
            pausedAt = nil
            status = nil
            baseline = await session.readSteps()
            latestSteps = baseline
            startTicking()
            return true
        case .pause:
            // Stamped at the press, not when the band gets round to answering.
            if pausedAt == nil { pausedAt = clock() }
            _ = await session.sport(.pause)
            return true
        case .resume:
            if let pausedAt { pausedTotal += max(0, clock().timeIntervalSince(pausedAt)) }
            pausedAt = nil
            _ = await session.sport(.resume)
            return true
        case .stop:
            _ = await session.sport(.stop)
            finish()
            return true
        case .query:
            return true
        }
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
        let meters = status?.distanceMeters ?? counted
        // The band counts small calories.
        let kcal = Double(status?.calories ?? 0) / 1000
        let hr = status?.heartRate.flatMap { (30...240).contains($0) ? $0 : nil }
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
                if let report = await self.session.sportStatus() { self.merge(report) }
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
        status = next
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
