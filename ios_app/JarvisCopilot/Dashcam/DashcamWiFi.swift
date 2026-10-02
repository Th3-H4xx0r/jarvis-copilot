import Foundation
import Network
import NetworkExtension
import UIKit

/// Knows when the phone is on the dashcam's Wi‑Fi.
///
/// Setup saves the network with `joinOnce = false`, so iOS rejoins it by itself whenever the
/// camera powers up — exactly like a home network. This class only watches: a Wi‑Fi path change
/// triggers an SSID check (`NEHotspotNetwork.fetchCurrent` is allowed because this app configured
/// the network). With the debug host set (simulator, fake camera) a reachable camera counts as joined.
@MainActor
final class DashcamWiFi: ObservableObject {
    static let shared = DashcamWiFi()

    @Published private(set) var onCamera = false
    @Published private(set) var currentSSID: String?
    var onChange: ((Bool) -> Void)?

    private var monitor: NWPathMonitor?
    private var debugPoll: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastPath: Network.NWPath?
    /// When the camera's Wi‑Fi went away, for rejoining after a drop.
    private(set) var lostAt: Date?
    private var lastRejoin: Date?
    static let rejoinWindow: TimeInterval = 600
    static let rejoinEvery: TimeInterval = 20

    private init() {}

    // MARK: Saving the network

    /// Saves the camera's network so iOS joins it automatically from now on, and joins it now.
    func save(ssid: String, password: String?) async throws {
        let config = (password ?? "").isEmpty
            ? NEHotspotConfiguration(ssid: ssid)
            : NEHotspotConfiguration(ssid: ssid, passphrase: password ?? "", isWEP: false)
        config.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated: break
            case .userDenied: throw DashcamError.busy("Joining the dashcam's Wi‑Fi was declined")
            case .invalidWPAPassphrase, .invalidWEPPassphrase: throw DashcamError.busy("That Wi‑Fi password is not valid")
            default: throw DashcamError.busy("Couldn't join \(ssid): \(error.localizedDescription)")
            }
        }
        await refresh()
    }

    func forget(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        onCamera = false
    }

    // MARK: Watching

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.lastPath = path
                await self?.refresh()
            }
        }
        m.start(queue: DispatchQueue(label: "jc.dashcam.wifi"))
        monitor = m
        startDebugPollIfNeeded()
        startWatchdog()
        Task { await refresh() }
    }

    /// While the app is open: re-check every few seconds (a path update can land before the SSID is
    /// readable, which left it "Away" on the camera's own Wi‑Fi), and after a drop rejoin the camera —
    /// iOS falls back to a network with internet and won't leave it for the camera on its own.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, UIApplication.shared.applicationState == .active else { continue }
                await self.refresh()
                await self.rejoinAfterDrop()
            }
        }
    }

    private func rejoinAfterDrop(now: Date = Date()) async {
        guard !onCamera, let lostAt, now.timeIntervalSince(lostAt) < Self.rejoinWindow,
              now.timeIntervalSince(lastRejoin ?? .distantPast) >= Self.rejoinEvery,
              DashcamSetupStore.debugHost() == nil, let setup = DashcamSetupStore.load(),
              let password = DashcamSetupStore.password else { return }   // never guess a password
        lastRejoin = now
        try? await save(ssid: setup.ssid, password: password)
    }

    /// The Reconnect button: join the camera's network now (a password given here is kept for next time).
    func reconnect(password typed: String? = nil) async throws {
        guard let setup = DashcamSetupStore.load() else { return }
        if let typed, !typed.isEmpty { DashcamSetupStore.password = typed }
        try await save(ssid: setup.ssid, password: DashcamSetupStore.password)
        if !onCamera {
            try? await Task.sleep(for: .seconds(3))      // DHCP on the camera's network
            await refresh()
        }
        if !onCamera { throw DashcamError.busy("Couldn't reach \(setup.ssid). Is the camera on?") }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        debugPoll?.cancel()
        debugPoll = nil
    }

    func refresh() async {
        guard let setup = DashcamSetupStore.load() else { set(false, ssid: nil); return }
        if let host = DashcamSetupStore.debugHost() {
            let found = await DashcamDetect.probe(host: host, timeout: 1.5) != nil
            set(found, ssid: found ? setup.ssid : nil)
            return
        }
        guard lastPath?.status != .unsatisfied else { set(false, ssid: nil); return }
        if let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid {
            set(ssid == setup.ssid, ssid: ssid)
            return
        }
        // No SSID to read (just joined, or a network this app didn't configure): ask the camera itself.
        let answered = await DashcamDetect.answers(family: setup.family, host: setup.host)
        set(answered, ssid: answered ? setup.ssid : nil)
    }

    private func set(_ value: Bool, ssid: String?) {
        currentSSID = ssid
        guard value != onCamera else { return }
        lostAt = value ? nil : Date()
        onCamera = value
        onChange?(value)
    }

    private func startDebugPollIfNeeded() {
        debugPoll?.cancel()
        guard DashcamSetupStore.debugHost() != nil else { return }
        debugPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
