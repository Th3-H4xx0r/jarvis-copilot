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
    @ObservationIgnored private let afterSave: (@MainActor () async -> Void)?
    @ObservationIgnored private var initialUser = ""
    @ObservationIgnored private var initialLogPath = ""
    @ObservationIgnored private var passwordSet = false
    @ObservationIgnored private var seeded = false
    /// The user changed a device's type or address since the last save, so a background
    /// refresh must not throw those edits away.
    @ObservationIgnored private var devicesEdited = false
    @ObservationIgnored private let gate = GameLoadGate()
    /// How long one detect/status load may take (the server answers in ≤10 s).
    @ObservationIgnored var loadTimeout: Double = 15

    /// `afterSave` runs once a save lands — the view passes the operational page's
    /// refresh so its status stops showing the old (rejected) login.
    init(client: GameStreamingAPI = GameStreamingClient(),
         afterSave: (@MainActor () async -> Void)? = nil) {
        self.client = client
        self.afterSave = afterSave
    }

    var passwordPlaceholder: String { passwordSet ? "Set — tap to replace" : "Not set" }

    /// Seed the login fields from the Power row's settings, once.
    func seed(from row: PowerRow) {
        guard !seeded else { return }
        seeded = true
        if case .text(let u)? = row.settings["user"] { user = u; initialUser = u }
        if case .text(let l)? = row.settings["log_path"] { logPath = l; initialLogPath = l }
        if case .secretSet(let set)? = row.settings["password"] { passwordSet = set }
    }

    /// The setup status headline, aware of whether a password is already stored, so a
    /// rejected login reads as "that login was rejected" rather than the neutral hint.
    var detectHeadline: String {
        guard let detect else { return "Checking your gaming PC…" }
        return detect.headline(passwordSet: passwordSet)
    }

    /// Detect Sunshine and load the device list (paired clients + saved targets). When
    /// the user hasn't entered a username, auto-fill it from the PC's Sunshine state file.
    /// Overlapping calls share one load (`fresh` waits and loads again, for after a
    /// change); `loading` clears on every path; each request is capped at `loadTimeout`.
    func refresh(fresh: Bool = false) async {
        await gate.run(fresh: fresh) { [weak self] in await self?.load() }
    }

    /// Refresh now and keep refreshing while the setup is on screen: every 5 s until
    /// Sunshine is found with a working login, then every 15 s.
    func keepFresh() async {
        while !Task.isCancelled {
            await refresh()
            let wait: Double = detect?.found == true ? 15 : 5
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let client = self.client
        let limit = loadTimeout
        async let detected = try? GameStreamingTimeout.run(seconds: limit) { try await client.detect() }
        async let loaded = try? GameStreamingTimeout.run(seconds: limit) { try await client.status() }
        if let d = await detected {
            detect = d
            if user.isEmpty, !d.username.isEmpty { user = d.username }
        }
        if let s = await loaded {
            let fresh = GameSetupModel.drafts(paired: s.paired, targets: s.targets)
            devices = devicesEdited ? GameSetupModel.merge(edited: devices, fresh: fresh) : fresh
        }
    }

    func setKind(_ kind: String, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].kind = kind
        devicesEdited = true
    }

    func setAddr(_ addr: String, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].tvAddr = addr
        devicesEdited = true
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
            case .pending:
                // The login lands once Face ID approves it; the setup's polling picks it up.
                return .ok("Approve the change with Face ID")
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
        devicesEdited = false
        // Re-check Sunshine with the new login, and refresh the operational status too, so
        // neither keeps showing the old (rejected) login.
        await refresh(fresh: true)
        await afterSave?()
        return .ok("Saved")
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
