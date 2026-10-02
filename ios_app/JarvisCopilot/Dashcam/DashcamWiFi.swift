import Foundation
import Network
import NetworkExtension

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
    private var lastPath: Network.NWPath?

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
        Task { await refresh() }
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
        let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid
        set(ssid == setup.ssid, ssid: ssid)
    }

    private func set(_ value: Bool, ssid: String?) {
        currentSSID = ssid
        guard value != onCamera else { return }
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
