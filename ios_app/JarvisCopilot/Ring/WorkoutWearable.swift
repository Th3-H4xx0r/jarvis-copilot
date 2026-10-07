import Combine
import Foundation

/// A wearable that can track a workout — the one adapter every workout-capable device plugs in
/// through. `RingWorkoutController` starts, pauses and stops the device's session through it
/// and hears its once-a-second packets as `RingSportTick`s, whichever device sends them, so the
/// Health card, the live sheet, the Live Activity, voice and the start screen's picker work the
/// same on each. A new device subclasses this, mirrors its link into `state` and `battery`, and
/// is added to the controller with `add(_:)`.
@MainActor
class WorkoutWearable: ObservableObject, Identifiable {
    /// The roster kind (`WearableKeepAlive.ring`, `.x5ring`, …).
    let kind: String
    /// The link, for the start screen.
    @Published var state: ConnectionState = .idle
    @Published var battery: RingBattery?
    /// Every packet of the device's session, in the R12's shape.
    var onTick: ((RingSportTick) -> Void)?
    var watching: Set<AnyCancellable> = []

    nonisolated var id: String { kind }

    init(kind: String) {
        self.kind = kind
    }

    /// The id the workout is saved under.
    var deviceID: String? { nil }
    var isPaired: Bool { WearableIdentity.remembered(kind) != nil }
    var name: String { WearableNames.shared.name(kind, fallback: fallbackName) }
    var fallbackName: String { "Wearable" }
    /// Whether a pause is read from the device's clock standing still. The R12's state byte
    /// lies, so its ticks decide; a device whose ticks carry no pause leaves it to the buttons.
    var pauseFromTicks: Bool { true }
    /// The device ends a session on its own after a stretch without steps — a strength
    /// workout, whose sets are logged on the phone, asks it to start again.
    var endsWhenStill: Bool { false }
    /// A session picked up after a relaunch was paused (for devices whose ticks can't say).
    var resumesPaused: Bool { false }

    /// It can signal on its own — a buzz, a light — and does when a strength rest runs out
    /// (its "Alert when a rest ends" switch, `WearableRestAlert`).
    var canSignal: Bool { false }
    /// What its signal is, for the switch: "Buzz", "Light".
    var signalName: String { "Alert" }
    func signal() async {}

    func ensureConnected() async -> Bool { false }
    /// Drops the link (the picker's Reconnect).
    func disconnect() {}
    /// Tells the device. False only when it refused a start (busy).
    @discardableResult func send(_ command: RingSportCommand, sport: Int) async -> Bool { true }
    /// The device's steps and metres today, for indoor workouts; nil when it can't say.
    func todayActivity() async -> (steps: Int, meters: Int)? { nil }
    /// The workout is over: the link it held goes back to the usual rules.
    func released() {}

    /// Mirrors a manager's link and battery into `state` and `battery`.
    func mirror(state: AnyPublisher<ConnectionState, Never>?, battery: AnyPublisher<RingBattery?, Never>?) {
        state?.receive(on: RunLoop.main).sink { [weak self] in self?.state = $0 }.store(in: &watching)
        battery?.receive(on: RunLoop.main).sink { [weak self] in self?.battery = $0 }.store(in: &watching)
    }
}

/// The Colmi R12: `0x77 [command, sport]` out, `0x78` ticks in — exactly the bytes the
/// controller always sent.
@MainActor
final class R12WorkoutWearable: WorkoutWearable {
    let session: RingSession
    private let connect: () async -> Bool
    private let drop: () -> Void
    private let device: () -> String?

    init(session: RingSession, connect: @escaping () async -> Bool, disconnect: @escaping () -> Void = {},
         deviceID: @escaping () -> String? = { nil }, state: AnyPublisher<ConnectionState, Never>? = nil) {
        self.session = session
        self.connect = connect
        self.drop = disconnect
        self.device = deviceID
        super.init(kind: WearableKeepAlive.ring)
        session.onSportTick = { [weak self] tick in self?.onTick?(tick) }
        mirror(state: state, battery: state == nil ? nil : session.$battery.eraseToAnyPublisher())
    }

    override var deviceID: String? { device() }
    override var fallbackName: String { "Colmi R12" }

    override func ensureConnected() async -> Bool { await connect() }
    override func disconnect() { drop() }

    @discardableResult
    override func send(_ command: RingSportCommand, sport: Int) async -> Bool {
        _ = try? await session.transport.perform(.phoneSport(command, sport: sport), until: .none)
        return true
    }

    override func todayActivity() async -> (steps: Int, meters: Int)? {
        guard let reply = try? await session.transport.perform(.todayActivity, until: .single).first,
              let totals = RingDecode.activity(reply.payload) else { return nil }
        return (totals.steps, totals.distanceMeters)
    }
    // released(): the R12's manager re-applies its link rules through the controller's `onEnded`.
}

/// The X5: `19 [action, sport]` out (1 start, 2 pause, 3 resume, 4 end), `18` ticks in.
///
/// Its ticks carry no sport and no pause, so this stamps the sport it started (kept in
/// defaults, so a workout picked up after a relaunch is still the right one) and the buttons
/// decide pauses. Its end packet carries no numbers either, so it repeats the last tick's.
@MainActor
final class X5WorkoutWearable: WorkoutWearable {
    private let session: X5Session
    private let connect: () async -> Bool
    private let drop: () -> Void
    private let release: () -> Void
    private let device: () -> String?
    private let defaults: UserDefaults
    private var last: RingSportTick?
    /// A start is in flight: what arrives now is the stray session's (or its end), not this one's.
    private var starting = false

    static let sportKey = "jc.x5.workout.sport"
    static let pausedKey = "jc.x5.workout.paused"

    init(session: X5Session, connect: @escaping () async -> Bool, disconnect: @escaping () -> Void = {},
         release: @escaping () -> Void = {}, deviceID: @escaping () -> String? = { nil },
         state: AnyPublisher<ConnectionState, Never>? = nil, defaults: UserDefaults = .standard) {
        self.session = session
        self.connect = connect
        self.drop = disconnect
        self.release = release
        self.device = deviceID
        self.defaults = defaults
        super.init(kind: WearableKeepAlive.x5ring)
        session.onWorkoutTick = { [weak self] tick in self?.receive(tick) }
        mirror(state: state, battery: state == nil ? nil : session.$battery.eraseToAnyPublisher())
    }

    override var deviceID: String? { device() }
    override var fallbackName: String { X5Ring.model }

    /// The X5 has no light command (its SDK and protocol sheet have none): its outer light shows
    /// while it charges and as it connects. So its signal is the link dropped and made again —
    /// the connect light, at the cost of a few seconds without its data.
    override var canSignal: Bool { isPaired }
    override var signalName: String { "Lights up as it reconnects (a few seconds without data)" }

    override func signal() async {
        drop()
        try? await Task.sleep(for: .seconds(1.5))
        _ = await connect()
    }
    override var pauseFromTicks: Bool { false }
    override var endsWhenStill: Bool { true }
    override var resumesPaused: Bool { defaults.bool(forKey: Self.pausedKey) }

    /// The shared list's id of the sport the X5 is running.
    private(set) var sportID: Int? {
        get { defaults.object(forKey: Self.sportKey) as? Int }
        set { defaults.set(newValue, forKey: Self.sportKey) }
    }

    override func ensureConnected() async -> Bool { await connect() }
    override func disconnect() { drop() }
    override func released() { release() }

    @discardableResult
    override func send(_ command: RingSportCommand, sport: Int) async -> Bool {
        let action: UInt8
        switch command {
        case .start: action = 1
        case .pause: action = 2
        case .resume: action = 3
        case .stop: action = 4
        case .query: action = 5
        }
        let x5 = Self.x5Sport(for: sport)
        if command == .start {
            sportID = sport
            last = nil
            starting = true
        }
        defaults.set(command == .pause, forKey: Self.pausedKey)
        defer {
            if command == .stop { sportID = nil }
            if command == .start { starting = false }
        }
        do {
            var reply = try await session.workout(action, sport: x5)
            if command == .start, !reply.ok {
                // Busy: a session the phone lost track of is still running. This start is
                // the one the person asked for, so that one ends.
                _ = try? await session.workout(4, sport: x5)
                reply = try await session.workout(1, sport: x5)
                if !reply.ok { sportID = nil }
            }
            return reply.ok || command != .start
        } catch {
            // No reply is not a refusal: the ticks (or their absence) settle it.
            return true
        }
    }

    func receive(_ tick: X5WorkoutTick) {
        // "No steps for 10 / 20 minutes — end?" The ring ends it itself at 30.
        if tick.inactivityPrompt != nil { return }
        // Mid-start: a busy ring's old session, and the end of it this start asked for.
        if starting { return }
        let sport = sportID ?? RingSport.otherID
        if tick.ended {
            defaults.set(false, forKey: Self.pausedKey)
            let ended = RingSportTick(sport: sport, state: .ended, elapsed: last?.elapsed ?? 0,
                                      heartRate: last?.heartRate, steps: last?.steps ?? 0,
                                      distanceMeters: last?.distanceMeters ?? 0, kilocalories: last?.kilocalories ?? 0)
            last = nil
            sportID = nil
            onTick?(ended)
            return
        }
        let mapped = Self.tick(tick, sport: sport)
        last = mapped
        onTick?(mapped)
    }

    nonisolated static func tick(_ t: X5WorkoutTick, sport: Int) -> RingSportTick {
        RingSportTick(sport: sport, state: .running, elapsed: t.seconds,
                      heartRate: (30...240).contains(t.heartRate) ? t.heartRate : nil,
                      steps: t.steps, distanceMeters: Int((max(0, t.km) * 1000).rounded()),
                      kilocalories: max(0, t.kcal))
    }

    /// The shared list's sports, as the X5 knows them (its 18; the rest record as a workout).
    nonisolated static func x5Sport(for id: Int) -> X5Sport {
        switch id {
        case 7, 40, 42: return .run
        case 4, 41: return .walk
        case 9, 24: return .cycling
        case 8: return .hiking
        case 22, 94: return .yoga
        case 5: return .ropeJump
        case 35: return .dance
        case 31: return .basketball
        case 32: return .football
        case 29: return .tennis
        case 21: return .badminton
        case 89: return .aerobics
        default: return .workout
        }
    }

    /// An X5 sport (as voice names it) on the shared list; the X5's own extras keep their name.
    nonisolated static func sport(for x5: X5Sport) -> RingSport {
        let id: Int
        switch x5 {
        case .run: id = 7
        case .walk: id = 4
        case .cycling: id = 9
        case .hiking: id = 8
        case .yoga: id = 22
        case .ropeJump: id = 5
        case .dance: id = 35
        case .basketball: id = 31
        case .football: id = 32
        case .tennis: id = 29
        case .badminton: id = 21
        case .aerobics: id = 89
        case .workout: id = RingSport.otherID
        case .meditation, .cricket, .pingPong, .sitUps, .volleyball:
            return RingSport(id: RingSport.otherID, name: x5.label, symbol: "figure.mixed.cardio")
        }
        return RingSport.withID(id)
    }
}

/// Which workout wearable the next workout uses.
enum WorkoutWearables {
    /// The one last chosen while it is still paired, else Jarvis Health's ring if it is, else
    /// the first paired one, else the first.
    static func preferred(stored: String?, health: String, kinds: [String], isPaired: (String) -> Bool) -> String {
        if let stored, kinds.contains(stored), isPaired(stored) { return stored }
        if kinds.contains(health), isPaired(health) { return health }
        return kinds.first(where: isPaired) ?? kinds.first ?? WearableKeepAlive.ring
    }
}
