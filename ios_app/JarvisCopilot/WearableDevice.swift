import Foundation

/// One command a device exposes. Maps 1:1 onto a JarvisCopilot bridge "skill":
/// `{"name": …, "description": …, "input_schema": {…}}` — see the protocol doc at the
/// top of `webui/api/device_bridge.py`.
struct DeviceCapability {
    let name: String
    let description: String
    /// JSON Schema for the arguments. Sent verbatim as `input_schema`.
    let inputSchema: [String: Any]

    var wireForm: [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }

    /// Convenience for the common "object with these properties" shape.
    static func schema(_ properties: [String: [String: Any]] = [:],
                       required: [String] = []) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { s["required"] = required }
        return s
    }
}

enum DeviceError: LocalizedError {
    case notConnected
    case unknownCommand(String)
    case badArgument(String)
    case confirmationRequired(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "device is not connected over Bluetooth"
        case .unknownCommand(let n):
            return "unknown command '\(n)'"
        case .badArgument(let m):
            return "bad argument: \(m)"
        case .confirmationRequired(let n):
            return "'\(n)' runs the UV lamp — pass confirm=true to proceed"
        }
    }
}

/// A physical product this app can drive. Implemented per model so the bridge and the
/// UI never have to special-case one device.
@MainActor
protocol WearableDevice: AnyObject {
    /// Product name, e.g. "VSITOO S1 Pro".
    static var model: String { get }
    /// Stable across launches once known. Falls back to the per-install CoreBluetooth
    /// identifier until the bottle reports its MAC.
    var deviceID: String { get }
    var isConnected: Bool { get }
    /// Self-describing command catalogue. This is what the AI reads.
    var capabilities: [DeviceCapability] { get }
    /// Current state as JSON-encodable values.
    func snapshot() -> [String: Any]
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any]
}

extension WearableDevice {
    /// The device's entry in a `list_devices` response.
    func descriptor() -> [String: Any] {
        [
            "device_id": deviceID,
            "model": Self.model,
            "connected": isConnected,
            "commands": capabilities.map(\.name),
        ]
    }
}

/// Everything the app can currently drive. The bridge asks this for skills and state;
/// the UI keeps it populated.
@MainActor
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()

    @Published private(set) var devices: [any WearableDevice] = []

    /// Bumped whenever the catalogue changes, so the bridge knows to re-register.
    @Published private(set) var generation = 0

    private init() {}

    func register(_ device: any WearableDevice) {
        guard !devices.contains(where: { $0.deviceID == device.deviceID }) else { return }
        devices.append(device)
        generation += 1
    }

    func remove(deviceID: String) {
        guard devices.contains(where: { $0.deviceID == deviceID }) else { return }
        devices.removeAll { $0.deviceID == deviceID }
        generation += 1
    }

    func device(id: String) -> (any WearableDevice)? {
        devices.first { $0.deviceID == id }
    }

    /// Every capability across every device, namespaced so two bottles don't collide.
    /// The bridge caps skills at 128, which we're nowhere near.
    func allSkills() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for device in devices {
            for capability in device.capabilities {
                var wire = capability.wireForm
                // Devices are addressed by argument rather than by skill name so the
                // catalogue stays stable when a bottle reconnects with a new UUID.
                var schema = capability.inputSchema
                var props = schema["properties"] as? [String: [String: Any]] ?? [:]
                props["device_id"] = [
                    "type": "string",
                    "description": "Which device to act on. Omit when only one is connected.",
                ]
                schema["properties"] = props
                wire["input_schema"] = schema
                out.append(wire)
            }
        }
        return out
    }

    /// Routes a bridge invoke to the right device.
    func invoke(skill: String, args: [String: Any]) async throws -> [String: Any] {
        let requested = args["device_id"] as? String
        let target: (any WearableDevice)?
        if let requested, !requested.isEmpty {
            target = device(id: requested)
        } else {
            target = devices.first { $0.capabilities.contains { $0.name == skill } }
        }
        guard let target else { throw DeviceError.unknownCommand(skill) }
        return try await target.invoke(skill, args: args)
    }
}
