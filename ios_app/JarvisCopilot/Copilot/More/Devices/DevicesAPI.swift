import Foundation

/// The paired-devices surface: list, revoke, log out, start a pairing code, and
/// the skills catalogue that backs the per-device ACL.
struct DevicesAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/devices` → `{devices: [...]}`.
    func list() async throws -> [Device] {
        let body = try await api.get("/api/devices").object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "devices")).map(Device.init(json:))
    }

    /// `GET /api/devices/skills` → `{skills: [...]}` — every skill a device may
    /// be granted, i.e. the ACL vocabulary.
    func allSkills() async throws -> [DeviceSkill] {
        let body = try await api.get("/api/devices/skills").object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "skills")).map(DeviceSkill.init(json:))
    }

    /// Remove the device and log it out.
    func revoke(_ id: String) async throws {
        _ = try await api.delete("/api/devices/\(id)")
    }

    /// Force re-authentication without un-pairing.
    func logout(_ id: String) async throws {
        _ = try await api.post("/api/devices/\(id)/logout", json: JSONObject())
    }

    /// Begin a pairing window; the reply carries the code and its expiry.
    func startPair(ttl: Int = 600, label: String? = nil) async throws -> JSONObject {
        var body: JSONObject = ["ttl": ttl]
        if let label { body["label"] = label }
        return try await api.post("/api/devices/pair/start", json: body).object()
    }

    /// Run one of a device's skills remotely.
    func invoke(deviceID: String, skill: String, args: JSONObject,
                timeout: Double = 30) async throws -> JSONObject {
        try await api.post("/api/devices/skills/invoke", json: [
            "device_id": deviceID,
            "skill": skill,
            "args": args,
            "timeout": timeout,
        ]).object()
    }
}
