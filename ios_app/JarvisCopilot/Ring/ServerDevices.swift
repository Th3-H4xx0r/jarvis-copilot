import Foundation

/// A device the server holds itself rather than through this phone: the Pod, an ESP32 board on
/// its own Wi-Fi, or a Mac / PC (jc-client). Its tools run through `/api/devices/skills/invoke`.
struct ServerDevice {
    let id: String
    let name: String
    let online: Bool
    let capabilities: [DeviceCapability]
    /// Set for a Mac or PC: it also answers to the power actions (`ComputerPowerAction`).
    var computer: ServerComputer? = nil
}

/// The server's boards as button actions: listed from `/api/devices`, run through the server.
@MainActor
enum ServerDevices {
    /// Overridable for tests.
    static var fetch: () async throws -> [[String: Any]] = { try await JarvisAPI.shared.devices(skills: true) }
    static var invoke: (String, String, [String: Any]) async throws -> [String: Any] = {
        try await JarvisPodAPI().invoke($0, $1, $2)
    }
    static var isPaired: () -> Bool = { BridgeClient.shared.isPaired }
    /// The Macs and PCs (the Agents card's list), by device id.
    static var computers: () async -> [String: (name: String, computer: ServerComputer)] = { await ComputerDirectory.load() }
    private static var cache: (at: Date, devices: [ServerDevice])?

    /// Boards only — a device whose every tool is `esp32_*` or `pod_*` (the server's own test for
    /// one) — and none this phone already reaches over Bluetooth.
    /// A Mac or PC from the Agents list is kept with every tool its jc-client offers (or none
    /// yet: it still has its power actions), named and online the way its Agents card is.
    static func parse(_ rows: [[String: Any]], onPhone: Set<String>,
                      computers: [String: (name: String, computer: ServerComputer)] = [:]) -> [ServerDevice] {
        var out: [ServerDevice] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, !onPhone.contains(id) else { return nil }
            let skills = (row["skills"] as? [[String: Any]] ?? []).compactMap { skill -> DeviceCapability? in
                guard let name = skill["name"] as? String, !name.isEmpty else { return nil }
                return DeviceCapability(name: name, description: skill["description"] as? String ?? "",
                                        inputSchema: skill["input_schema"] as? [String: Any] ?? [:])
            }
            if let known = computers[id] {
                return ServerDevice(id: id, name: known.name, online: known.computer.awake, capabilities: skills,
                                    computer: known.computer)
            }
            guard !skills.isEmpty,
                  skills.allSatisfy({ $0.name.hasPrefix("esp32_") || $0.name.hasPrefix("pod_") }) else { return nil }
            return ServerDevice(id: id, name: row["name"] as? String ?? "Board",
                                online: row["online"] as? Bool ?? false, capabilities: skills)
        }
        // A computer the device list didn't return (unpaired record, older server) still has power.
        let listed = Set(out.map(\.id))
        for (id, known) in computers.sorted(by: { $0.key < $1.key }) where !listed.contains(id) {
            out.append(ServerDevice(id: id, name: known.name, online: known.computer.awake, capabilities: [],
                                    computer: known.computer))
        }
        return out
    }

    /// The boards, kept for five minutes: the list with every catalogue is a large read.
    static func load(maxAge: TimeInterval = 300) async -> [ServerDevice] {
        if let cache, Date().timeIntervalSince(cache.at) < maxAge { return cache.devices }
        guard isPaired(), let rows = try? await fetch() else { return cache?.devices ?? [] }
        let devices = parse(rows, onPhone: Set(DeviceRegistry.shared.devices.map(\.deviceID)),
                            computers: await computers())
        cache = (Date(), devices)
        return devices
    }

    static func offers(deviceID: String, skill: String) async -> Bool {
        await load().contains { d in
            d.id == deviceID && (d.capabilities.contains { $0.name == skill }
                                 || (d.computer != nil && ComputerPowerAction(skill: skill) != nil))
        }
    }

    /// Runs one tool and returns a line for the log / the button's caption. A computer's power
    /// action goes through the server's power path (Wake works while it sleeps).
    static func run(deviceID: String, skill: String, values: [String: String]) async -> String {
        if let power = ComputerPowerAction(skill: skill) {
            return await ComputerPowerRunner.run(power, deviceID: deviceID)
        }
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
