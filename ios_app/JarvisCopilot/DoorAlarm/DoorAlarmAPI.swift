import Foundation

/// `/api/door` on the Jarvis server — the door alarm lives there (it must work while this phone
/// sleeps). Disarm and silence carry a Face ID proof over `jarvis-home|<action>|<nonce>|<ts>`.
struct DoorAlarmAPI: Sendable {
    var api: JarvisAPI
    static let prefix = "/api/door"
    /// The Face ID message domain — never the car's.
    static let domain = "jarvis-home"

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    func state() async throws -> DoorState {
        DoorState(json: try await api.get(Self.prefix + "/state", timeout: 20).object())
    }

    func history(limit: Int = 100, contact: String? = nil) async throws -> [DoorEvent] {
        var query = ["limit": String(limit)]
        if let contact { query["contact"] = contact }
        let o = try await api.get(Self.prefix + "/history", query: query, timeout: 20).object()
        return (o["events"] as? [[String: Any]] ?? []).enumerated().map { DoorEvent(json: $1, index: $0) }
    }

    func arm(_ mode: String, bypass: [String] = []) async throws -> DoorState {
        DoorState(json: try await api.post(Self.prefix + "/arm", json: ["mode": mode, "bypass": bypass], timeout: 20).object())
    }

    /// "arm_now" (skip the exit delay) or "cancel_arming" (during the exit delay).
    func action(_ name: String) async throws -> DoorState {
        DoorState(json: try await api.post(Self.prefix + "/" + name, timeout: 20).object())
    }

    /// `action` is "disarm" or "silence".
    func send(_ action: String, proof: ToyotaApprover.Proof) async throws -> DoorState {
        let body: [String: Any] = ["nonce": proof.nonce, "ts": proof.ts, "signature": proof.signature]
        return DoorState(json: try await api.post(Self.prefix + "/" + action, json: body, timeout: 20).object())
    }

    func approvals() async throws -> [DoorApproval] {
        let o = try await api.get(Self.prefix + "/approvals", timeout: 20).object()
        return (o["approvals"] as? [[String: Any]] ?? []).compactMap { DoorApproval(json: $0) }
    }

    func approve(_ approval: DoorApproval, proof: ToyotaApprover.Proof) async throws -> DoorState {
        let o = try await api.post(Self.prefix + "/approvals/\(approval.id)/approve",
                                   json: ["ts": proof.ts, "signature": proof.signature], timeout: 20).object()
        return DoorState(json: o)
    }

    func deny(_ approval: DoorApproval) async throws {
        _ = try await api.post(Self.prefix + "/approvals/\(approval.id)/deny")
    }

    /// Sets one hub data point; returns how it went ("esp32" / "cloud"). Throws when the hub didn't confirm.
    func set(_ code: String, value: Any) async throws -> String {
        let o = try await api.post(Self.prefix + "/set", json: ["code": code, "value": value], timeout: 30).object()
        return o["via"] as? String ?? "hub"
    }

    func updateSettings(_ body: [String: Any]) async throws {
        _ = try await api.post(Self.prefix + "/settings", json: body, timeout: 20)
    }

    func rename(_ name: String) async throws {
        _ = try await api.post(Self.prefix + "/rename", json: ["name": name], timeout: 30)
    }

    // MARK: Setup

    struct CloudDevice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let product: String
        let category: String
        let online: Bool
    }

    struct Proxy: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    func saveCredentials(accessID: String, secret: String, region: String) async throws {
        _ = try await api.post(Self.prefix + "/setup/credentials",
                               json: ["access_id": accessID, "secret": secret, "region": region], timeout: 40)
    }

    func cloudDevices() async throws -> [CloudDevice] {
        let o = try await api.get(Self.prefix + "/setup/devices", timeout: 40).object()
        return (o["devices"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return CloudDevice(id: id, name: d["name"] as? String ?? id,
                               product: d["product_name"] as? String ?? "",
                               category: d["category"] as? String ?? "",
                               online: d["online"] as? Bool ?? false)
        }
    }

    func pick(_ deviceID: String) async throws -> DoorState {
        DoorState(json: try await api.post(Self.prefix + "/setup/pick", json: ["dev_id": deviceID], timeout: 60).object())
    }

    func proxies() async throws -> (boards: [Proxy], current: String?) {
        let o = try await api.get(Self.prefix + "/proxies", timeout: 20).object()
        let boards = (o["proxies"] as? [[String: Any]] ?? []).compactMap { p -> Proxy? in
            guard let id = p["id"] as? String else { return nil }
            return Proxy(id: id, name: p["name"] as? String ?? id)
        }
        return (boards, o["current"] as? String)
    }

    func setProxy(_ boardID: String?) async throws {
        _ = try await api.post(Self.prefix + "/setup/proxy", json: ["board_id": boardID ?? ""], timeout: 30)
    }

    func network() async throws -> [String: Any] {
        try await api.get(Self.prefix + "/network", timeout: 30).object()
    }

    func firmware() async throws -> [[String: Any]] {
        let o = try await api.get(Self.prefix + "/firmware", timeout: 30).object()
        return o["firmware"] as? [[String: Any]] ?? []
    }

    func upgrade(_ firmwareID: Any) async throws {
        _ = try await api.post(Self.prefix + "/firmware/upgrade", json: ["firmware_id": firmwareID], timeout: 30)
    }
}
