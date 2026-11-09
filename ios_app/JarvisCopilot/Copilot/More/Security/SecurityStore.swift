import Foundation

/// More → Security: the Security Advisor's state for the page, loaded on demand. Block and Allow
/// on an alert go through Face ID first (signed in the `jarvis-security` domain with the same
/// Secure Enclave key as the car and the door alarm); Dismiss, Undo and Settings don't.
@MainActor
final class SecurityStore: ObservableObject {
    static let shared = SecurityStore()

    enum Action: String, Sendable {
        case block, allow, dismiss

        var needsFaceID: Bool { self != .dismiss }
    }

    /// The feed's Source filter (matched against the event's `source`).
    enum SourceFilter: String, CaseIterable, Hashable, Sendable {
        case all, device, host, agent

        var label: String {
            switch self {
            case .all: return "All"
            case .device: return "Devices"
            case .host: return "Server"
            case .agent: return "Agent"
            }
        }
    }

    /// The feed's Level filter (matched against the event's `outcome`).
    enum LevelFilter: String, CaseIterable, Hashable, Sendable {
        case all, alert, block, digest

        var label: String {
            switch self {
            case .all: return "All"
            case .alert: return "Alerts"
            case .block: return "Blocks"
            case .digest: return "Digest"
            }
        }
    }

    @Published private(set) var status: SecurityStatus?
    @Published private(set) var alerts: [SecurityAlert] = []
    @Published private(set) var events: [SecurityEvent] = []
    @Published private(set) var blocks: [SecurityBlock] = []
    @Published private(set) var digests: [SecurityDigest] = []
    @Published private(set) var settings: SecuritySettingsPayload?
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    /// What is running right now: an alert id, an IP, or "settings".
    @Published private(set) var busy: String?
    /// A short line after an action ("Blocked", "Couldn't …").
    @Published var notice: String?
    @Published var source: SourceFilter = .all
    @Published var level: LevelFilter = .all

    let api: SecurityAPI
    let approver: ToyotaApprover

    init(api: SecurityAPI = SecurityAPI(), approver: ToyotaApprover? = nil) {
        self.api = api
        self.approver = approver ?? ToyotaApprover.shared
    }

    // MARK: Derived

    /// "All quiet" / "1 open alert" / "2 open alerts" — the web page's strings; "" before a load.
    static func statusLine(_ status: SecurityStatus?) -> String {
        guard let status else { return "" }
        switch status.openAlerts {
        case ..<1: return "All quiet"
        case 1: return "1 open alert"
        default: return "\(status.openAlerts) open alerts"
        }
    }

    var statusLine: String { Self.statusLine(status) }

    static func filter(_ events: [SecurityEvent], source: SourceFilter, level: LevelFilter) -> [SecurityEvent] {
        events.filter {
            (source == .all || $0.source == source.rawValue) && (level == .all || $0.outcome == level.rawValue)
        }
    }

    var filteredEvents: [SecurityEvent] { Self.filter(events, source: source, level: level) }

    var openAlerts: [SecurityAlert] { alerts.filter(\.isOpen) }

    // MARK: Loading

    func load() async {
        guard api.api.isPaired else { problem = "Pair with a Jarvis server first."; return }
        // Each section on its own: one failing endpoint must not blank the page.
        let api = self.api
        async let status = Self.attempt { try await api.status() }
        async let alerts = Self.attempt { try await api.alerts(status: "open") }
        async let events = Self.attempt { try await api.events() }
        async let blocks = Self.attempt { try await api.blocks() }
        async let digests = Self.attempt { try await api.digests() }
        async let settings = Self.attempt { try await api.settings() }
        let results = await (status, alerts, events, blocks, digests, settings)
        var errors: [String] = []
        func take<T>(_ r: Result<T, Error>) -> T? {
            switch r {
            case .success(let v): return v
            case .failure(let e):
                if !wasCancelled(e) { errors.append(apiErrorMessage(e)) }
                return nil
            }
        }
        if let v = take(results.0) { self.status = v }
        if let v = take(results.1) { self.alerts = v }
        if let v = take(results.2) { self.events = v }
        if let v = take(results.3) { self.blocks = v }
        if let v = take(results.4) { self.digests = v }
        if let v = take(results.5) { self.settings = v }
        problem = errors.first
        loaded = true
    }

    private nonisolated static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: Actions

    /// Block / Allow (Face ID first) or Dismiss one alert. True when the server took it.
    @discardableResult
    func resolve(_ alertID: String, _ action: Action) async -> Bool {
        busy = alertID
        defer { busy = nil }
        do {
            var proof: ToyotaApprover.Proof?
            if action.needsFaceID {
                proof = try await approver.proof(for: "\(action.rawValue):\(alertID)",
                                                 title: action == .block ? "Block this" : "Allow this",
                                                 domain: SecurityAPI.domain)
            }
            try await api.resolve(alertID, action: action.rawValue, proof: proof)
            notice = action == .block ? "Blocked" : action == .allow ? "Allowed for 7 days" : "Dismissed"
            alerts.removeAll { $0.id == alertID }
            Task { await load() }
            return true
        } catch CarSignError.cancelled {
            return false
        } catch {
            if case .http(403, _)? = error as? APIError, action.needsFaceID { approver.forgetRegistration() }
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
            return false
        }
    }

    func undo(_ ip: String) async {
        busy = ip
        defer { busy = nil }
        do {
            try await api.undoBlock(ip)
            notice = "\(ip) unblocked"
            blocks.removeAll { $0.ip == ip }
        } catch {
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
        }
        await load()
    }

    func save(_ draft: SecuritySettings, model: SecurityModelOption?) async {
        busy = "settings"
        defer { busy = nil }
        var body: [String: Any] = ["settings": draft.json]
        if let model { body["model"] = ["provider": model.provider, "model": model.model] }
        do {
            try await api.saveSettings(body)
            notice = "Settings saved"
        } catch {
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
        }
        await load()
    }
}
