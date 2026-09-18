import Combine
import Foundation

/// A workout on the ring, from the countdown to the summary.
///
/// The ring runs the session: it keeps the optical sensor on, counts steps
/// and time, and pushes a packet a second (`RingSportTick`). This starts,
/// pauses and stops it, believes the ticks rather than the replies (a start
/// the ring refused — it is on its charger — answers with an "ended" tick
/// and nothing else), folds them into what the live screen shows, and builds
/// the summary. A workout still running when the app comes back is picked up
/// from its ticks.
@MainActor
final class RingWorkoutController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 3, 2, 1 before the ring is told.
        case countdown(Int)
        case starting
        case running
        case paused
        case ending
        case finished(RingWorkout)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sport: RingSport?
    @Published private(set) var tick: RingSportTick?
    /// When the workout began (the phone's clock, or elapsed back from a re-attached tick).
    @Published private(set) var startedAt: Date?
    /// Steps a minute over the last minute.
    @Published private(set) var cadence: Int?
    /// Seconds in heart-rate zones 1–5 so far.
    @Published private(set) var zoneSeconds = [0, 0, 0, 0, 0]
    /// Outdoors: the phone's GPS distance and pace (seconds per km).
    @Published private(set) var gpsDistance: Double?
    @Published private(set) var pace: Double?

    /// Seconds of countdown; tests set 0.
    var countdownSeconds = 3
    /// How long a start may go without a running tick before it is a failure.
    var startTimeout: TimeInterval = 5
    /// How long "end" waits for the ring's last tick before summarising anyway.
    var endTimeout: TimeInterval = 3
    /// Handed the workout when the summary is saved.
    var onSave: ((RingWorkout) -> Void)?

    private let session: RingSession
    private let ensureConnected: () async -> Bool
    private let age: () -> Int
    private let location: WorkoutLocationTracking?
    private let liveActivity: WorkoutLiveActivity?
    /// Heart rate every 5 s so far (0 where there was no reading).
    @Published private(set) var heartRates: [Int] = []
    private var stepMarks: [(elapsed: Int, steps: Int)] = []
    private var lastElapsed = -1
    private var pending: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

    init(session: RingSession, ensureConnected: @escaping () async -> Bool, age: @escaping () -> Int = { 30 },
         location: WorkoutLocationTracking? = nil, liveActivity: WorkoutLiveActivity? = nil) {
        self.session = session
        self.ensureConnected = ensureConnected
        self.age = age
        self.location = location
        self.liveActivity = liveActivity
        session.onSportTick = { [weak self] tick in self?.receive(tick) }
    }

    /// A workout is under way (the link is held and the measurer steps aside).
    var isActive: Bool {
        switch phase {
        case .countdown, .starting, .running, .paused, .ending: return true
        default: return false
        }
    }

    /// The live screen is up: during a workout and while its summary shows.
    var isPresenting: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Heart-rate zone 1–5 for the current reading: 50/60/70/80/90 % of 220 − age.
    var zone: Int? {
        guard let hr = tick?.heartRate else { return nil }
        return Self.zone(hr, age: age())
    }

    static func zone(_ hr: Int, age: Int) -> Int {
        let ratio = Double(hr) / Double(max(100, 220 - age))
        switch ratio {
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    // MARK: Actions

    func start(_ sport: RingSport) {
        guard !isActive else { return }
        reset()
        self.sport = sport
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            var count = self.countdownSeconds
            while count > 0 {
                self.phase = .countdown(count)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, case .countdown = self.phase else { return }
                count -= 1
            }
            self.phase = .starting
            guard await self.ensureConnected() else {
                return self.fail("Can't reach the ring — bring it closer and try again.")
            }
            guard self.phase == .starting else { return }
            _ = try? await self.session.transport.perform(.phoneSport(.start, sport: sport.id), until: .none)
            if sport.outdoor { self.location?.start { [weak self] distance, pace in
                self?.gpsDistance = distance
                self?.pace = pace
            } }
            try? await Task.sleep(for: .seconds(self.startTimeout))
            if self.phase == .starting {
                self.fail("The ring didn't start — take it off its charger and try again.")
            }
        }
    }

    /// Before the ring has been told: nothing to stop.
    func cancelCountdown() {
        guard case .countdown = phase else { return }
        pending?.cancel()
        phase = .idle
    }

    func pause() {
        guard phase == .running, let sport else { return }
        phase = .paused
        send(.pause, sport)
    }

    func resume() {
        guard phase == .paused, let sport else { return }
        phase = .running
        send(.resume, sport)
    }

    func end() {
        guard phase == .running || phase == .paused, let sport else { return }
        phase = .ending
        send(.stop, sport)
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.endTimeout))
            if self.phase == .ending { self.finish() }
        }
    }

    /// The summary's Save or Discard.
    func close(save: Bool) {
        if case .finished(let workout) = phase, save { onSave?(workout) }
        reset()
        phase = .idle
    }

    // MARK: Ticks

    func receive(_ tick: RingSportTick) {
        switch tick.state {
        case .ended:
            if phase == .starting {
                // The ring answers a refused start (charging) with an ended tick.
                fail("The ring didn't start — take it off its charger and try again.")
            } else if phase == .running || phase == .paused || phase == .ending {
                record(tick)
                finish()
            }
            return
        case .running, .paused:
            switch phase {
            case .idle:
                // A workout the ring kept running while the app was away.
                sport = RingSport.withID(tick.sport)
                phase = .running
            case .finished, .failed, .countdown:
                // A stray tick after the summary (or before the ring was told).
                return
            default:
                break
            }
            if phase == .starting || startedAt == nil {
                startedAt = Date().addingTimeInterval(-Double(tick.elapsed))
            }
            if phase == .starting || phase == .running || phase == .paused {
                phase = tick.state == .paused ? .paused : .running
            }
            record(tick)
        }
    }

    private func record(_ tick: RingSportTick) {
        self.tick = tick
        if let sport, tick.state != .ended {
            let meters = gpsDistance ?? Double(tick.distanceMeters)
            liveActivity?.update(sport: sport, running: tick.state == .running, elapsed: tick.elapsed,
                                 heartRate: tick.heartRate, distanceKm: meters > 0 ? meters / 1000 : nil,
                                 zone: tick.heartRate.map { Self.zone($0, age: age()) })
        }
        guard tick.elapsed != lastElapsed else { return }
        let seconds = lastElapsed < 0 ? 1 : max(1, tick.elapsed - lastElapsed)
        lastElapsed = tick.elapsed
        if let hr = tick.heartRate {
            zoneSeconds[Self.zone(hr, age: age()) - 1] += seconds
        }
        if tick.elapsed % 5 == 0 { heartRates.append(tick.heartRate ?? 0) }
        stepMarks.append((tick.elapsed, tick.steps))
        stepMarks.removeAll { $0.elapsed < tick.elapsed - 60 }
        if let first = stepMarks.first, tick.elapsed - first.elapsed >= 20 {
            cadence = Int((Double(tick.steps - first.steps) / Double(tick.elapsed - first.elapsed) * 60).rounded())
        }
    }

    private func finish() {
        pending?.cancel()
        location?.stop()
        liveActivity?.end()
        guard let sport, let startedAt else { return reset(to: .idle) }
        let last = tick
        let readings = heartRates.filter { $0 > 0 }
        let workout = RingWorkout(
            sport: sport.id, sportName: sport.name, start: startedAt, end: Date(),
            activeSeconds: last?.elapsed ?? 0, steps: last?.steps ?? 0,
            distanceMeters: gpsDistance ?? Double(last?.distanceMeters ?? 0),
            distanceSource: gpsDistance == nil ? "ring" : "gps",
            kilocalories: last?.kilocalories ?? 0,
            heartRateAverage: readings.isEmpty ? nil : readings.reduce(0, +) / readings.count,
            heartRateMax: readings.max(), heartRates: heartRates, zoneSeconds: zoneSeconds)
        phase = .finished(workout)
    }

    private func fail(_ message: String) {
        pending?.cancel()
        location?.stop()
        liveActivity?.end()
        phase = .failed(message)
    }

    private func send(_ command: RingSportCommand, _ sport: RingSport) {
        Task { [session] in _ = try? await session.transport.perform(.phoneSport(command, sport: sport.id), until: .none) }
    }

    private func reset(to next: Phase? = nil) {
        tick = nil
        startedAt = nil
        cadence = nil
        zoneSeconds = [0, 0, 0, 0, 0]
        gpsDistance = nil
        pace = nil
        heartRates = []
        stepMarks = []
        lastElapsed = -1
        if let next { phase = next }
    }
}

/// Outdoor distance and pace from the phone's GPS.
@MainActor
protocol WorkoutLocationTracking: AnyObject {
    /// Reports distance (m) and pace (s/km over the last km) as they change.
    func start(_ update: @escaping (Double, Double?) -> Void)
    func stop()
}
