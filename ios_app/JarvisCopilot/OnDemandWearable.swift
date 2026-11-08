import Foundation

/// A Bluetooth wearable linked on demand: brought up when something needs it, let go once
/// nothing holds it. The rules live here once, so the R12, the X5 and the band can't drift
/// apart (the R12's copy once lost the failed-connect exit and the workout hold).
@MainActor
protocol OnDemandWearable: AnyObject {
    var state: ConnectionState { get }
    var bluetoothReady: Bool { get }
    /// Connecting, discovering or ready.
    var linkIsUp: Bool { get }
    /// "ring", "x5", "band": how the device reads in the log.
    var linkLogName: String { get }

    // What holds the link up.
    var keepAliveEnabled: Bool { get }
    /// The device's own screen is open.
    var screenIsOpen: Bool { get }
    /// The Health tab is open and reads this device.
    var healthIsOpen: Bool { get }
    var holdsLinkForWorkout: Bool { get }

    /// A setup, sync or reading is in flight: an idle drop waits for it.
    var isWorking: Bool { get }
    /// The per-connection setup (capabilities, settings) hasn't finished.
    var isSettingUp: Bool { get }
    var idleDropTask: Task<Void, Never>? { get set }

    /// Opens the link to the known peripheral, without a scan; nothing when it is already opening.
    func startLink()
    /// Lets an idle link go.
    func dropIdleLink() async
}

extension OnDemandWearable {
    var holdsLink: Bool { keepAliveEnabled || screenIsOpen || healthIsOpen || holdsLinkForWorkout }

    /// Reconnects if needed and waits until the link is usable.
    func ensureConnected(timeout: TimeInterval = 12) async -> Bool {
        if state == .ready { return true }
        guard bluetoothReady else { return false }
        startLink()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .ready { return true }
            if case .failed = state { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return state == .ready
    }

    /// Waits (bounded) for the per-connection setup, so capability checks see real values.
    func waitForSetup(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isSettingUp, state == .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Lets an on-demand link go once nothing holds it, after a grace and after any work
    /// in flight (a first sync after launch easily outlasts the grace).
    func releaseIfIdle() {
        guard !holdsLink else { return }
        idleDropTask?.cancel()
        idleDropTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WearableKeepAlive.idleGraceSeconds))
            while !Task.isCancelled, self?.isWorking == true {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let self, !Task.isCancelled, !self.holdsLink else { return }
            JcLog.devices.notice("\(self.linkLogName, privacy: .public): idle after on-demand use; dropping the link")
            await self.dropIdleLink()
        }
    }

    /// For a hold's `didSet`: taking a hold keeps the link (and brings it up if asked);
    /// letting the last one go starts the idle drop.
    func holdChanged(_ held: Bool, connectIfDown: Bool = false) {
        if held {
            idleDropTask?.cancel()
            idleDropTask = nil
            if connectIfDown, !linkIsUp { Task { _ = await ensureConnected(timeout: 12) } }
        } else {
            releaseIfIdle()
        }
    }
}
