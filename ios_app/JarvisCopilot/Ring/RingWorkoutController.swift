import Combine
import Foundation
import UIKit

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
    /// Outdoors: the route so far — distance, pace, climbing, and calories
    /// when no wearable measures them.
    @Published private(set) var routeProgress = RouteProgress()
    /// An outdoor workout with no wearable: the phone keeps the clock, and
    /// pause and resume are the buttons. No ring is told anything.
    @Published private(set) var phoneOnly = false
    /// A finished outdoor workout's route, until its summary is saved or discarded.
    @Published private(set) var finishedRoute: WorkoutRoute?
    /// When the ring's last tick arrived: the clock runs on between ticks, and
    /// a long gap is shown as waiting rather than a frozen screen.
    @Published private(set) var lastTickAt: Date?
    /// The live sheet is up. Dragging it down hides it — the workout carries
    /// on, shown as a card on the Health tab that brings it back.
    @Published var showsLive = false
    /// A strength workout's log and rest timer. Strength runs on the phone's
    /// clock; the ring's session underneath only records heart rate.
    @Published private(set) var strength: StrengthSession?
    /// Why a strength workout has no heart rate (no ring, on its charger…).
    @Published private(set) var vitalsNote: String?
    /// A strength workout's heart rate, a reading a second.
    private(set) var heartSamples: [HeartSample] = []

    /// Seconds of countdown; tests set 0.
    var countdownSeconds = 3
    /// How long a start may go without a running tick before it is a failure.
    var startTimeout: TimeInterval = 5
    /// How long "end" waits for the ring's last tick before summarising anyway.
    var endTimeout: TimeInterval = 3
    /// Handed the workout when the summary is saved.
    var onSave: ((RingWorkout) -> Void)?
    /// Handed an outdoor workout's route when its summary is saved (before `onSave`).
    var onSaveRoute: ((WorkoutRoute, RingWorkout) -> Void)?
    /// The workout is over (finished, failed or closed): the link it held can
    /// go back to the usual rules.
    var onEnded: (() -> Void)?

    private let session: RingSession
    private let ensureConnected: () async -> Bool
    private let age: () -> Int
    private let location: WorkoutLocationTracking?
    private let liveActivity: WorkoutLiveActivity?
    private let training: TrainingStore?
    private let library: ExerciseLibrary?
    private let alerts: RestAlerting?
    private let profile: () -> VitalsProfile
    private let clock: () -> Date
    private let defaults: UserDefaults
    /// A phone-only workout's paused time so far, and when the current pause began.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    /// The route was told to pause (it follows the workout's phase).
    private var routePaused = false
    /// Keeps a phone-only workout's Live Activity current (no ring ticks do).
    private var phoneTicker: Task<Void, Never>?
    /// The ring was told to start a strength session (so it is told to stop).
    private var ringStarted = false
    /// Autosave and the Live Activity follow the log a moment behind typing.
    private var autosave: Task<Void, Never>?
    /// When the ring was last told to stop a session nobody is logging.
    private var lastStrayStop = Date.distantPast
    /// Heart rate every 5 s so far (0 where there was no reading).
    @Published private(set) var heartRates: [Int] = []
    private var stepMarks: [(elapsed: Int, steps: Int)] = []
    private var lastElapsed = -1
    private var pending: Task<Void, Never>?
    /// When the person last ended or discarded a workout. Ticks the ring
    /// sends after that are a session that did not hear the stop — it is told
    /// again, never brought back on screen.
    private var endedAt: Date?
    static let endedGrace: TimeInterval = 120
    /// Ticks in a row whose active time did not move: three is a pause.
    private var stillTicks = 0
    /// When the person last paused or resumed: the ring's next few ticks may
    /// predate it, so they do not overrule the button for a moment.
    private var commandAt: Date?
    private var watching: Set<AnyCancellable> = []

    init(session: RingSession, ensureConnected: @escaping () async -> Bool, age: @escaping () -> Int = { 30 },
         location: WorkoutLocationTracking? = nil, liveActivity: WorkoutLiveActivity? = nil,
         training: TrainingStore? = nil, library: ExerciseLibrary? = nil, alerts: RestAlerting? = nil,
         profile: @escaping () -> VitalsProfile = { .fallback }, clock: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.session = session
        self.ensureConnected = ensureConnected
        self.age = age
        self.location = location
        self.liveActivity = liveActivity
        self.training = training
        self.library = library
        self.alerts = alerts
        self.profile = profile
        self.clock = clock
        self.defaults = defaults
        session.onSportTick = { [weak self] tick in self?.receive(tick) }
        // Coming forward is when iOS allows the Live Activity a background
        // request was refused; and one left by a crash with no workout to
        // follow is cleared once the ring has had time to report.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appCameForward() }
            .store(in: &watching)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.isActive else { return }
            self.liveActivity?.end()
        }
        // Leaving the app saves the log at once, not a moment later.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.saveStrengthNow() }
            .store(in: &watching)
        // A strength workout finished but not saved comes back as its summary;
        // one the app was closed (or crashed) in the middle of, running.
        if let finished = training?.finishedWorkout {
            sport = RingSport.withID(RingSport.strengthID)
            showsLive = true
            phase = .finished(finished)
        } else if let log = training?.activeLog {
            begin(log)
        } else if let saved = PhoneWorkout.load(defaults) {
            resumePhoneOnly(saved)
        }
    }

    private func appCameForward() {
        guard isActive else { return }
        if phoneOnly {
            liveActivity?.retry()
            return pushPhoneActivity()
        }
        if let strength {
            strength.resync()
            liveActivity?.retry()
            return pushStrengthActivity()
        }
        guard let tick else { return }
        liveActivity?.retry()
        pushLiveActivity(tick)
    }

    /// The seconds the clock shows. Strength counts from its start; a ring
    /// workout from the ring's own active time, carried on between ticks.
    func elapsed(at date: Date) -> Int {
        if strength != nil, let startedAt { return max(0, Int(date.timeIntervalSince(startedAt))) }
        if phoneOnly, let startedAt {
            let paused = pausedTotal + (pausedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
            return max(0, Int(date.timeIntervalSince(startedAt) - paused))
        }
        let since = lastTickAt.map { date.timeIntervalSince($0) } ?? 0
        return (tick?.elapsed ?? 0) + (phase == .running ? Int(min(max(since, 0), 3)) : 0)
    }

    private func pushLiveActivity(_ tick: RingSportTick) {
        guard let sport, tick.state != .ended else { return }
        let meters = gpsDistance ?? Double(tick.distanceMeters)
        liveActivity?.update(sport: sport, running: phase != .paused, elapsed: tick.elapsed,
                             heartRate: tick.heartRate, distanceKm: meters > 0 ? meters / 1000 : nil,
                             zone: tick.heartRate.map { Self.zone($0, age: age()) })
    }

    /// The route so far, for the live map.
    var liveRoute: WorkoutRoute? { location?.route }
    /// The phone's pedometer (a phone-only workout's steps and cadence).
    var phoneSteps: Int? { location?.steps }
    var phoneCadence: Int? { location?.cadence }

    /// Where strength workouts keep their templates and history.
    var strengthStore: TrainingStore { training ?? .shared }

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

    nonisolated static func zone(_ hr: Int, age: Int) -> Int {
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
        // A summary still on screen is kept, not lost to the next workout.
        if case .finished = phase { close(save: true) }
        // Strength is logged set by set, whoever starts it.
        if sport.id == RingSport.strengthID, training != nil { return startStrength(template: nil) }
        guard !isActive else { showsLive = true; return }
        reset()
        endedAt = nil
        showsLive = true
        self.sport = sport
        // Outdoors with no wearable chosen, the phone records it alone.
        phoneOnly = sport.outdoor && !WorkoutMonitorPreference.usesRing
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
            if self.phoneOnly { return self.beginPhoneOnly() }
            self.phase = .starting
            guard await self.ensureConnected() else {
                return self.fail("Can't reach the ring — bring it closer and try again.")
            }
            guard self.phase == .starting else { return }
            _ = try? await self.session.transport.perform(.phoneSport(.start, sport: sport.id), until: .none)
            if sport.outdoor { self.startLocation() }
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
        guard phase == .running, strength == nil, let sport else { return }
        phase = .paused
        commandAt = Date()
        pauseRoute()
        if phoneOnly {
            pausedAt = clock()
            savePhoneWorkout()
            return pushPhoneActivity()
        }
        send(.pause, sport)
    }

    func resume() {
        guard phase == .paused, strength == nil, let sport else { return }
        phase = .running
        commandAt = Date()
        stillTicks = 0
        resumeRoute()
        if phoneOnly {
            if let pausedAt { pausedTotal += max(0, clock().timeIntervalSince(pausedAt)) }
            pausedAt = nil
            savePhoneWorkout()
            return pushPhoneActivity()
        }
        send(.resume, sport)
    }

    func end() {
        if strength != nil { return finishStrength() }
        if phoneOnly, phase == .running || phase == .paused {
            endedAt = Date()
            return finish()
        }
        guard phase == .running || phase == .paused, let sport else { return }
        endedAt = Date()
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
        if case .finished(let workout) = phase, save {
            if workout.isStrength { training?.record(workout) }
            if let finishedRoute { onSaveRoute?(finishedRoute, workout) }
            onSave?(workout)
        }
        if endedAt == nil || strength != nil, sport != nil { endedAt = Date() }
        training?.saveFinished(nil)
        clearStrength()
        reset()
        showsLive = false
        phase = .idle
    }

    // MARK: Ticks

    func receive(_ tick: RingSportTick) {
        if strength != nil { return receiveDuringStrength(tick) }
        // The ring wasn't started for a phone-only workout: its ticks aren't this one's.
        if phoneOnly { return }
        if case .finished(let workout) = phase, workout.isStrength {
            // A strength summary is up and the ring still runs its session:
            // it missed the stop, so it hears it again.
            if tick.state != .ended { stopStraySession() }
            return
        }
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
                if let endedAt, Date().timeIntervalSince(endedAt) < Self.endedGrace {
                    // One the person ended that the ring is still running: stop it again.
                    send(.stop, RingSport.withID(tick.sport))
                    return
                }
                // A workout the ring kept running while the app was away.
                if tick.sport == RingSport.strengthID, let training {
                    // Only a workout the phone was logging comes back; a
                    // strength session with nothing logged is a leftover.
                    guard let log = training.activeLog else {
                        if tick.state != .ended { stopStraySession() }
                        return
                    }
                    ringStarted = true
                    begin(log, ringRunning: true)
                    return receiveDuringStrength(tick)
                }
                let resumed = RingSport.withID(tick.sport)
                sport = resumed
                phase = .running
                if resumed.outdoor { startLocation(resuming: true) }
            case .finished, .failed, .countdown:
                // A stray tick after the summary (or before the ring was told).
                return
            default:
                break
            }
            if phase == .starting || startedAt == nil {
                startedAt = Date().addingTimeInterval(-Double(tick.elapsed))
            }
            // Running or paused is read from the ring's clock, not its state
            // byte: this ring reports "paused" while its time runs on (QRing
            // treats that value as running too). Time moving is running; three
            // ticks without it is a pause.
            let moved = lastElapsed < 0 || tick.elapsed > lastElapsed
            stillTicks = moved ? 0 : stillTicks + 1
            let settled = commandAt.map { Date().timeIntervalSince($0) > 2.5 } ?? true
            if phase == .starting {
                phase = .running
            } else if settled, phase == .running || phase == .paused {
                if moved { phase = .running } else if stillTicks >= 3 { phase = .paused }
            }
            // The route pauses with the ring, however the pause came about.
            if phase == .paused { pauseRoute() } else if phase == .running { resumeRoute() }
            record(tick)
        }
    }

    private func startLocation(resuming: Bool = false) {
        guard let location, let sport else { return }
        routePaused = false
        // Each point carries the ring's reading when it is fresh.
        location.heartRate = { [weak self] in
            guard let self, let at = self.lastTickAt, Date().timeIntervalSince(at) < 5 else { return nil }
            return self.tick?.heartRate
        }
        location.start(sport: sport.id, weightKg: profile().weightKg ?? 70, at: startedAt ?? clock(),
                       resuming: resuming) { [weak self] progress in
            self?.routeProgress = progress
            self?.gpsDistance = progress.distance
            self?.pace = progress.pace
        }
    }

    private func pauseRoute() {
        guard sport?.outdoor == true, !routePaused else { return }
        routePaused = true
        location?.pause()
    }

    private func resumeRoute() {
        guard sport?.outdoor == true, routePaused else { return }
        routePaused = false
        location?.resume()
    }

    // MARK: Phone only

    /// A phone-only workout, as it is kept across a relaunch.
    struct PhoneWorkout: Codable, Equatable {
        static let key = "jc.workout.phoneActive"
        var sport: Int
        var start: Date
        var pausedTotal: Double
        var pausedAt: Date?

        static func load(_ defaults: UserDefaults) -> PhoneWorkout? {
            guard let data = defaults.data(forKey: key),
                  let saved = try? JSONDecoder().decode(PhoneWorkout.self, from: data),
                  Date().timeIntervalSince(saved.start) < 12 * 3600 else { return nil }
            return saved
        }
    }

    private func beginPhoneOnly() {
        startedAt = clock()
        pausedTotal = 0
        pausedAt = nil
        phase = .running
        startLocation()
        savePhoneWorkout()
        startPhoneTicker()
    }

    /// Back after a relaunch in the middle of one: same clock, same route.
    private func resumePhoneOnly(_ saved: PhoneWorkout) {
        sport = RingSport.withID(saved.sport)
        phoneOnly = true
        startedAt = saved.start
        pausedTotal = saved.pausedTotal
        pausedAt = saved.pausedAt
        phase = saved.pausedAt == nil ? .running : .paused
        showsLive = true
        startLocation(resuming: true)
        if saved.pausedAt != nil { pauseRoute() }
        startPhoneTicker()
    }

    private func startPhoneTicker() {
        phoneTicker?.cancel()
        phoneTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pushPhoneActivity()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func pushPhoneActivity() {
        guard phoneOnly, isActive, let sport else { return }
        let meters = routeProgress.distance
        liveActivity?.update(sport: sport, running: phase == .running, elapsed: elapsed(at: clock()), heartRate: nil,
                             distanceKm: meters > 0 ? meters / 1000 : nil, zone: nil)
    }

    private func savePhoneWorkout() {
        guard phoneOnly, let sport, let startedAt else { return }
        let saved = PhoneWorkout(sport: sport.id, start: startedAt, pausedTotal: pausedTotal, pausedAt: pausedAt)
        defaults.set(try? JSONEncoder().encode(saved), forKey: PhoneWorkout.key)
    }

    private func clearPhoneWorkout() {
        defaults.removeObject(forKey: PhoneWorkout.key)
    }

    private func record(_ tick: RingSportTick) {
        self.tick = tick
        lastTickAt = Date()
        pushLiveActivity(tick)
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
        phoneTicker?.cancel()
        showsLive = true
        defer { onEnded?() }
        let route = location?.stop()
        liveActivity?.end()
        clearPhoneWorkout()
        guard let sport, let startedAt else { return reset(to: .idle) }
        let last = tick
        let readings = heartRates.filter { $0 > 0 }
        let ringKcal = last?.kilocalories ?? 0
        var workout = RingWorkout(
            sport: sport.id, sportName: sport.name, start: startedAt, end: Date(),
            activeSeconds: phoneOnly ? elapsed(at: clock()) : last?.elapsed ?? 0,
            steps: last?.steps ?? location?.steps ?? 0,
            distanceMeters: gpsDistance ?? Double(last?.distanceMeters ?? 0),
            distanceSource: gpsDistance == nil ? "ring" : "gps",
            kilocalories: ringKcal > 0 ? ringKcal : routeProgress.kilocalories,
            heartRateAverage: readings.isEmpty ? nil : readings.reduce(0, +) / readings.count,
            heartRateMax: readings.max(), heartRates: heartRates, zoneSeconds: zoneSeconds)
        if ringKcal <= 0, routeProgress.kilocalories > 0 { workout.kcalSource = "estimate" }
        workout.route = route.map(RouteMath.summary)
        finishedRoute = route
        phase = .finished(workout)
    }

    private func fail(_ message: String) {
        pending?.cancel()
        phoneTicker?.cancel()
        showsLive = true
        defer { onEnded?() }
        location?.stop()
        clearPhoneWorkout()
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
        routeProgress = RouteProgress()
        finishedRoute = nil
        phoneOnly = false
        pausedTotal = 0
        pausedAt = nil
        routePaused = false
        phoneTicker?.cancel()
        lastTickAt = nil
        heartRates = []
        stepMarks = []
        lastElapsed = -1
        stillTicks = 0
        commandAt = nil
        if let next { phase = next }
    }
}

/// Outdoor workouts' route from the phone's GPS (and barometer, pedometer).
@MainActor
protocol WorkoutLocationTracking: AnyObject {
    /// Starts recording. `resuming` picks up the route checkpointed for this
    /// sport (the app was relaunched mid-workout). Reports as the route grows.
    func start(sport: Int, weightKg: Double, at start: Date, resuming: Bool,
               update: @escaping (RouteProgress) -> Void)
    func pause()
    func resume()
    /// Stops, and hands back the route (nil when it never had two fixes).
    @discardableResult func stop() -> WorkoutRoute?
    /// The route so far, for the map.
    var route: WorkoutRoute? { get }
    var progress: RouteProgress { get }
    /// The wearable's reading, stamped on each point.
    var heartRate: (() -> Int?)? { get set }
    /// The phone's pedometer: steps since the start, and steps a minute.
    var steps: Int? { get }
    var cadence: Int? { get }
    var lastFix: CLLocationCoordinate2D? { get }
}

// MARK: - Strength

extension RingWorkoutController {
    /// Start logging a strength workout, from a template or empty. It runs at
    /// once, ring or no ring; the ring's session only adds heart rate.
    func startStrength(template: WorkoutTemplate?) {
        guard training != nil, library != nil else { return }
        if case .finished = phase { close(save: true) }
        guard !isActive else { showsLive = true; return }
        reset()
        endedAt = nil
        let now = clock().wholeSeconds
        begin(template.map { StrengthSession.log(from: $0, at: now) } ?? .empty(at: now))
    }

    fileprivate func begin(_ log: StrengthLog, ringRunning: Bool = false) {
        guard let training, let library else { return }
        let strength = StrengthSession(log: log, mode: .live, store: training, library: library, alerts: alerts, now: clock)
        strength.onChange = { [weak self, weak strength] in
            guard let self, let strength, self.strength === strength else { return }
            self.scheduleAutosave()
        }
        self.strength = strength
        sport = RingSport.withID(RingSport.strengthID)
        startedAt = log.started
        training.saveActive(log)
        vitalsNote = nil
        showsLive = true
        phase = .running
        if !ringRunning {
            // The start screen's choice: no wearable means no ring session at all.
            if WorkoutMonitorPreference.usesRing {
                startRingVitals()
            } else {
                vitalsNote = "No wearable chosen — logging sets without heart rate."
            }
        }
        pushStrengthActivity()
    }

    /// Ask the ring for a strength session underneath — unless it already
    /// sends one (a workout picked up after a relaunch).
    private func startRingVitals() {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            guard await self.ensureConnected() else {
                if self.strength != nil { self.vitalsNote = "No ring — logging sets only." }
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.strength != nil else { return }
            if self.lastTickAt == nil {
                _ = try? await self.session.transport.perform(.phoneSport(.start, sport: RingSport.strengthID), until: .none)
            }
            self.ringStarted = true
            try? await Task.sleep(for: .seconds(self.startTimeout))
            if !Task.isCancelled, self.strength != nil, self.lastTickAt == nil {
                self.vitalsNote = "The ring didn't start — logging sets only."
            }
        }
    }

    /// Every change is saved and shown a moment later — a keystroke's worth
    /// of typing is one write, not six.
    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveStrengthNow()
        }
    }

    fileprivate func saveStrengthNow() {
        autosave?.cancel()
        guard let strength, phase == .running else { return }
        training?.saveActive(strength.log)
        pushStrengthActivity()
    }

    /// Tell the ring to stop a session nobody is logging (at most every 5 s).
    fileprivate func stopStraySession() {
        guard clock().timeIntervalSince(lastStrayStop) > 5 else { return }
        lastStrayStop = clock()
        let session = self.session
        Task { _ = try? await session.transport.perform(.phoneSport(.stop, sport: RingSport.strengthID), until: .none) }
    }

    fileprivate func receiveDuringStrength(_ tick: RingSportTick) {
        // Another sport's leftover session says nothing about this workout.
        guard phase == .running, tick.sport == RingSport.strengthID else { return }
        switch tick.state {
        case .ended:
            ringStarted = false
            vitalsNote = lastTickAt == nil ? "The ring didn't start — take it off its charger for heart rate."
                : "The ring stopped — logging sets only."
        case .running, .paused:
            self.tick = tick
            lastTickAt = clock()
            vitalsNote = nil
            // Sending, whoever started it: it gets its stop at the end.
            ringStarted = true
            if let hr = tick.heartRate {
                heartSamples.append(HeartSample(at: clock(), bpm: hr))
                // Four hours of readings is plenty for any workout.
                if heartSamples.count > 14_400 { heartSamples.removeFirst(heartSamples.count - 14_400) }
            }
            pushStrengthActivity()
        }
    }

    fileprivate func pushStrengthActivity() {
        guard let strength, phase == .running else { return }
        // Short: the activity's whole payload has to fit in 4 KB.
        let sport = RingSport(id: RingSport.strengthID, name: String(strength.log.name.prefix(40)),
                              symbol: RingSport.withID(RingSport.strengthID).symbol)
        liveActivity?.update(sport: sport, running: true, elapsed: elapsed(at: clock()), heartRate: tick?.heartRate,
                             distanceKm: nil, zone: zone, restEnds: strength.rest?.ends,
                             restStarted: strength.rest?.started, detail: strength.detail.map { String($0.prefix(90)) })
    }

    /// Finish: the log with each set's heart rate and records, calories and
    /// effort, as the summary shows it.
    fileprivate func finishStrength() {
        guard let strength, let startedAt, phase == .running else { return }
        pending?.cancel()
        strength.cancelRest()
        strength.focus = nil
        if ringStarted { stopRing() }
        let end = clock()
        endedAt = end
        let profile = profile()
        var log = SessionVitals.annotate(strength.log, samples: heartSamples, end: end)
        let marks = TrainingMath.newRecords(in: log, history: training?.logs ?? [])
        for e in log.exercises.indices {
            for s in log.exercises[e].sets.indices {
                log.exercises[e].sets[s].records = marks[log.exercises[e].sets[s].id] ?? []
            }
        }
        let calories = SessionVitals.activeCalories(samples: heartSamples, start: startedAt, end: end, profile: profile,
                                                    ringKcal: tick?.kilocalories)
        let readings = heartSamples.map(\.bpm)
        let workout = RingWorkout(
            sport: RingSport.strengthID, sportName: log.name, start: startedAt, end: end,
            activeSeconds: max(0, Int(end.timeIntervalSince(startedAt))), steps: tick?.steps ?? 0, distanceMeters: 0,
            distanceSource: "ring", kilocalories: calories.kcal.rounded(),
            heartRateAverage: readings.isEmpty ? nil : readings.reduce(0, +) / readings.count,
            heartRateMax: readings.max(),
            heartRates: SessionVitals.series5s(samples: heartSamples, start: startedAt, end: end),
            zoneSeconds: SessionVitals.zoneSeconds(samples: heartSamples, age: profile.age),
            strength: log,
            effort: readings.isEmpty ? nil : SessionVitals.effort(trimp: SessionVitals.trimp(samples: heartSamples, profile: profile)),
            kcalSource: calories.source)
        liveActivity?.end()
        // Kept until Save or Discard: a relaunch shows the summary again
        // rather than the workout running on.
        autosave?.cancel()
        training?.saveActive(nil)
        training?.saveFinished(workout)
        showsLive = true
        phase = .finished(workout)
        onEnded?()
    }

    /// Throw the workout in progress away.
    func cancelStrength() {
        guard strength != nil else { return }
        pending?.cancel()
        if ringStarted { stopRing() }
        endedAt = clock()
        liveActivity?.end()
        clearStrength()
        reset()
        showsLive = false
        phase = .idle
        onEnded?()
    }

    private func stopRing() {
        ringStarted = false
        let session = self.session
        Task { _ = try? await session.transport.perform(.phoneSport(.stop, sport: RingSport.strengthID), until: .none) }
    }

    fileprivate func clearStrength() {
        guard let strength else { return }
        autosave?.cancel()
        strength.cancelRest()
        strength.onChange = nil
        training?.saveActive(nil)
        self.strength = nil
        vitalsNote = nil
        heartSamples = []
        ringStarted = false
    }
}
