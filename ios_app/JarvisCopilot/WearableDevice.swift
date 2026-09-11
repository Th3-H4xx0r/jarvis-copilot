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

/// Everything the app can currently drive. The bridge asks this for skills and state;
/// the UI keeps it populated.
@MainActor
final class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()

    @Published private(set) var devices: [any WearableDevice] = []

    private init() {}

    func register(_ device: any WearableDevice) {
        guard !devices.contains(where: { $0.deviceID == device.deviceID }) else { return }
        devices.append(device)
    }

    func remove(deviceID: String) {
        guard devices.contains(where: { $0.deviceID == deviceID }) else { return }
        devices.removeAll { $0.deviceID == deviceID }
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
        // `device_id` picks BETWEEN devices offering the same skill; it does not
        // override which skill was asked for. Honour it only when that device
        // actually has the skill, otherwise a `wearables_connect` naming a bottle
        // would route into the bottle — which has no such command — instead of the
        // hub that does.
        let offersSkill = { (d: any WearableDevice) in d.capabilities.contains { $0.name == skill } }
        let target: (any WearableDevice)?
        if let requested, !requested.isEmpty, let d = device(id: requested), offersSkill(d) {
            target = d
        } else {
            target = devices.first(where: offersSkill)
        }
        guard let target else { throw DeviceError.unknownCommand(skill) }
        return try await target.invoke(skill, args: args)
    }
}

extension DeviceRegistry {
    /// Adds or removes a wearable to match its "Share with Jarvis" setting, and pins
    /// its identity so it keeps the same id — and can be re-registered — while its
    /// link is down. `advertisedElsewhere` keeps it off the phone's list when
    /// something else already registers it with Jarvis.
    func syncMembership(of device: any WearableDevice, identity key: String, model: String,
                        advertisedElsewhere: Bool = false) {
        WearableIdentity.remember(device.deviceID, for: key)
        let shouldShare = BridgeClient.isExposed(device.deviceID) && !advertisedElsewhere
        guard shouldShare != (self.device(id: device.deviceID) != nil) else { return }
        if shouldShare {
            register(device)
            BridgeClient.remember(deviceID: device.deviceID, model: model)
        } else {
            remove(deviceID: device.deviceID)
            BridgeClient.forget(deviceID: device.deviceID)   // opted out, not merely offline
        }
        BridgeClient.shared.sendRegistration()
    }
}
