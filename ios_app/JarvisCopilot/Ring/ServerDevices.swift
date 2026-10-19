import Foundation

/// A device the server holds itself rather than through this phone: the Pod, or an ESP32 board on
/// its own Wi-Fi. Its tools run through `/api/devices/skills/invoke`.
struct ServerDevice {
    let id: String
    let name: String
    let online: Bool
    let capabilities: [DeviceCapability]
}

/// The server's boards as button actions: listed from `/api/devices`, run through the server.
@MainActor
enum ServerDevices {
    /// Overridable for tests.
    static var fetch: () async throws -> [[String: Any]] = {
        try await JarvisAPI.shared.get("/api/devices", query: ["skills": "1"]).array(key: "devices")
            .compactMap { $0 as? [String: Any] }
    }
    static var invoke: (String, String, [String: Any]) async throws -> [String: Any] = {
        try await JarvisPodAPI().invoke($0, $1, $2)
    }
    static var isPaired: () -> Bool = { BridgeClient.shared.isPaired }
    private static var cache: (at: Date, devices: [ServerDevice])?

    /// Boards only — a device whose every tool is `esp32_*` or `pod_*` (the server's own test for
    /// one) — and none this phone already reaches over Bluetooth.
    static func parse(_ rows: [[String: Any]], onPhone: Set<String>) -> [ServerDevice] {
        rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, !onPhone.contains(id) else { return nil }
            let skills = (row["skills"] as? [[String: Any]] ?? []).compactMap { skill -> DeviceCapability? in
                guard let name = skill["name"] as? String, !name.isEmpty else { return nil }
                return DeviceCapability(name: name, description: skill["description"] as? String ?? "",
                                        inputSchema: skill["input_schema"] as? [String: Any] ?? [:])
            }
            guard !skills.isEmpty,
                  skills.allSatisfy({ $0.name.hasPrefix("esp32_") || $0.name.hasPrefix("pod_") }) else { return nil }
            return ServerDevice(id: id, name: row["name"] as? String ?? "Board",
                                online: row["online"] as? Bool ?? false, capabilities: skills)
        }
    }

    /// The boards, kept for five minutes: the list with every catalogue is a large read.
    static func load(maxAge: TimeInterval = 300) async -> [ServerDevice] {
        if let cache, Date().timeIntervalSince(cache.at) < maxAge { return cache.devices }
        guard isPaired(), let rows = try? await fetch() else { return cache?.devices ?? [] }
        let devices = parse(rows, onPhone: Set(DeviceRegistry.shared.devices.map(\.deviceID)))
        cache = (Date(), devices)
        return devices
    }

    static func offers(deviceID: String, skill: String) async -> Bool {
        await load().contains { $0.id == deviceID && $0.capabilities.contains { $0.name == skill } }
    }

    /// Runs one tool and returns a line for the log / the button's caption.
    static func run(deviceID: String, skill: String, values: [String: String]) async -> String {
        guard let device = await load().first(where: { $0.id == deviceID }),
              let capability = device.capabilities.first(where: { $0.name == skill }) else {
            return "\(skill.replacingOccurrences(of: "_", with: " ")) unavailable: that device isn't connected to Jarvis right now"
        }
        do {
            let args = try SkillArgsForm.validatedArguments(values, schema: capability.inputSchema)
            let result = try await invoke(deviceID, skill, args)
            guard !result.isEmpty, let data = try? JSONSerialization.data(withJSONObject: result),
                  let text = String(data: data, encoding: .utf8) else { return skill }
            return "\(skill): \(text.prefix(120))"
        } catch {
            return "\(skill) failed: \(error.localizedDescription)"
        }
    }

    static func forgetCache() { cache = nil }
}
