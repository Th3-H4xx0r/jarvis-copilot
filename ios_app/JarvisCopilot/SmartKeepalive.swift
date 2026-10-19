import Combine
import Foundation
import Network
import UIKit

/// When the background keepalive is worth its battery: "Smart", his pick on Oct 18 2026 after the
/// first clean night (80 → 65 % in 8 h, Jarvis itself at 8 CPU-s an hour, so what was left was the
/// cost of being awake at all: the silent audio, the band link, the socket's pings).
///
/// Awake while he uses the app and for 30 minutes after, on Wi‑Fi, on the charger, with the car
/// (CarPlay, car audio, the dashcam's Wi‑Fi) and during a workout; a voice turn counts as use.
/// Out on cellular and idle past that it lets go: iOS suspends the app, the socket is closed
/// so the server pushes instead, and a command wakes it by push (a few seconds, best effort).
/// Low Power Mode and the dashcam's own hold stay in `BridgeClient.syncKeepalive`.
struct KeepalivePolicy: Equatable {
    static let idleGrace: TimeInterval = 30 * 60

    var foreground = true
    /// When he last left the screen (or a voice turn was last seen holding the session).
    var lastUse: Date?
    /// Until the first path update says otherwise: a launch shouldn't drop and re-open the socket.
    var onWiFi = true
    var charging = false
    var inCar = false
    var workout = false

    /// Held for a reason the clock alone doesn't end.
    var held: Bool { foreground || onWiFi || charging || inCar || workout }

    func wantsAwake(at now: Date) -> Bool {
        held || (lastUse.map { now.timeIntervalSince($0) < Self.idleGrace } ?? false)
    }

    /// When the answer turns to "sleep" by the clock alone; nil when it won't.
    func expiry(after now: Date) -> Date? {
        guard !held, let lastUse else { return nil }
        let end = lastUse.addingTimeInterval(Self.idleGrace)
        return end > now ? end : nil
    }
}

/// Feeds `KeepalivePolicy` from the phone (network path, charger, car, workout, screen, voice) and
/// tells `onChange` when its answer flips, so `BridgeClient` re-syncs the keepalive.
@MainActor
final class SmartKeepalive {
    static let shared = SmartKeepalive()

    private(set) var policy = KeepalivePolicy()
    /// The answer flipped (or a background wake asked again).
    var onChange: (() -> Void)?

    private let clock: () -> Date
    private let voiceLive: () -> Bool
    private let onPower: () -> Bool
    private var wasAwake = true
    private var monitor: NWPathMonitor?
    private var watches: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var expiryTask: Task<Void, Never>?

    /// `voiceLive` is optional rather than defaulted: a default argument cannot touch a
    /// `@MainActor` singleton.
    init(clock: @escaping () -> Date = Date.init, voiceLive: (() -> Bool)? = nil, onPower: (() -> Bool)? = nil) {
        self.clock = clock
        self.voiceLive = voiceLive ?? { !AudioSessionArbiter.shared.holders.subtracting([.keepalive]).isEmpty }
        self.onPower = onPower ?? {
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
    }

    var wantsAwake: Bool { policy.wantsAwake(at: clock()) }

    /// Watch the path, the charger, the car and the workout. Idempotent.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.update { $0.onWiFi = wifi } }
        }
        monitor.start(queue: DispatchQueue(label: "jc.keepalive.path", qos: .utility))
        self.monitor = monitor
        UIDevice.current.isBatteryMonitoringEnabled = true
        watches.append(NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readCharger() }
        })
        CarPresence.shared.start()
        CarPresence.shared.$inCar.removeDuplicates()
            .sink { [weak self] on in self?.update { $0.inCar = on } }
            .store(in: &cancellables)
        WearablesHub.shared.ring.workout.$phase.map(\.isActive).removeDuplicates()
            .sink { [weak self] on in self?.update { $0.workout = on } }
            .store(in: &cancellables)
        // A launch into the background (a push, a refresh) is not use: no 30 minutes for it.
        let foreground = UIApplication.shared.applicationState != .background
        update { $0.foreground = foreground }
        readCharger()
    }

    /// The app came to the screen (or CarPlay's) or left it. Leaving starts the 30 minutes.
    func setForeground(_ on: Bool) {
        let now = clock()
        update {
            if $0.foreground, !on { $0.lastUse = now }
            $0.foreground = on
        }
    }

    /// A background wake (app refresh): re-read what a suspended app hears nothing about (the
    /// charger), then have `onChange` re-sync even if the answer stands, since that sync is also
    /// the repair for an engine iOS stopped.
    func refresh() {
        policy.charging = onPower()
        evaluate(force: true)
    }

    func update(_ change: (inout KeepalivePolicy) -> Void) {
        var next = policy
        change(&next)
        guard next != policy else { return }
        policy = next
        evaluate()
    }

    private func readCharger() {
        let charging = onPower()
        update { $0.charging = charging }
    }

    private func evaluate(force: Bool = false) {
        let now = clock()
        // A turn started in the background (Siri, the Talk widget) holds its own claim; while it
        // runs and for 30 minutes after, it counts like the screen.
        if !policy.foreground, voiceLive() { policy.lastUse = now }
        let awake = policy.wantsAwake(at: now)
        scheduleExpiry(policy.expiry(after: now))
        if awake != wasAwake {
            wasAwake = awake
            EnergyLedger.shared.count(awake ? "keepalive.smart.wake" : "keepalive.smart.sleep")
            onChange?()
        } else if force {
            onChange?()
        }
    }

    private func scheduleExpiry(_ at: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let at else { return }
        let wait = max(0, at.timeIntervalSince(clock())) + 1
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
