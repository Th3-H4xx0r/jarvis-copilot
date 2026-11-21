import Foundation
import Observation

/// Backs the Game Streaming setup page: the Sunshine detect result, the login draft,
/// and the device-type list (auto-loaded from Sunshine's paired clients, each type
/// pre-guessed and editable). Save writes the login (Power settings) and the device
/// mapping (structured, no JSON) in one go.
@MainActor
@Observable
final class GameStreamingSetupStore {
    private(set) var detect: GameDetect?
    private(set) var devices: [GameDeviceDraft] = []
    private(set) var loading = false

    /// The login the user sets in Sunshine itself — the only manual input. Password is
    /// write-only: empty means "leave what's stored".
    var user = ""
    var password = ""
    var logPath = ""

    @ObservationIgnored private let client: GameStreamingAPI
    @ObservationIgnored private var initialUser = ""
    @ObservationIgnored private var initialLogPath = ""
    @ObservationIgnored private var passwordSet = false
    @ObservationIgnored private var seeded = false

    init(client: GameStreamingAPI = GameStreamingClient()) { self.client = client }

    var passwordPlaceholder: String { passwordSet ? "Set — tap to replace" : "Not set" }

    /// Seed the login fields from the Power row's settings, once.
    func seed(from row: PowerRow) {
        guard !seeded else { return }
        seeded = true
        if case .text(let u)? = row.settings["user"] { user = u; initialUser = u }
        if case .text(let l)? = row.settings["log_path"] { logPath = l; initialLogPath = l }
        if case .secretSet(let set)? = row.settings["password"] { passwordSet = set }
    }

    /// Detect Sunshine and load the device list (paired clients + saved targets).
    func refresh() async {
        loading = true
        defer { loading = false }
        async let detected = try? client.detect()
        async let loaded = try? client.status()
        if let d = await detected { detect = d }
        if let s = await loaded {
            devices = GameSetupModel.drafts(paired: s.paired, targets: s.targets)
        }
    }

    func setKind(_ kind: String, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].kind = kind
    }

    func setAddr(_ addr: String, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].tvAddr = addr
    }

    /// Save the login (only what changed) and the whole device mapping.
    @discardableResult
    func save(row: PowerRow, power: PowerState) async -> GameActionResult {
        var changes: [String: Any] = [:]
        if user != initialUser { changes["user"] = user }
        if logPath != initialLogPath { changes["log_path"] = logPath }
        if !password.isEmpty { changes["password"] = password }
        if !changes.isEmpty {
            switch await power.setSettings(row.id, changes) {
            case .failed(let message): return .failed(message)
            case .pending: return .ok("Approve the change with Face ID")
            case .done:
                initialUser = user
                initialLogPath = logPath
                if !password.isEmpty { passwordSet = true; password = "" }
            }
        }
        do {
            try await client.setTargets(devices.map {
                GameTargetEdit(name: $0.name, kind: $0.kind,
                               tvAddr: $0.kind == "androidtv" ? $0.tvAddr : "")
            })
        } catch {
            return .failed(Self.message(error))
        }
        await refresh()
        return .ok("Saved")
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
