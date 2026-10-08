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

/// A wearable that can display notification cards declares one of these so the
/// Code Master settings page shows a per-event toggle for it automatically.
struct NotificationChannelInfo: Equatable, Sendable {
    let key: String
    let label: String
    let symbol: String
    let defaultOn: Bool

    var wireForm: [String: Any] {
        ["key": key, "label": label, "icon": symbol, "default_on": defaultOn]
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
    /// If this device can display notification cards, return its channel info.
    var notificationChannel: NotificationChannelInfo? { get }
    /// Forward a notification card to this device (title + body text).
    func forwardNotification(title: String, body: String)
    /// Shown in Jarvis's CarPlay Wearables tab. Off unless a device type opts in —
    /// only things worth reaching from the driver's seat (the dashcam).
    var carEnabled: Bool { get }
    /// The `LinkableWearable` kind this device is, if any (`"dashcam"`). A linked device is
    /// listed by its host, not on its own.
    var linkKind: String? { get }
    /// Current state as JSON-encodable values.
    func snapshot() -> [String: Any]
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any]
}

extension WearableDevice {
    var notificationChannel: NotificationChannelInfo? { nil }
    func forwardNotification(title: String, body: String) {}
    var carEnabled: Bool { false }
    var linkKind: String? { nil }
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

    /// One tool per command, with explicit target choices. Ring forms consume
    /// the same per-device capability schemas used to build this AI catalogue.
    func allSkills() -> [[String: Any]] {
        var offerings: [String: [(String, DeviceCapability)]] = [:]
        for device in devices {
            for capability in device.capabilities { offerings[capability.name, default: []].append((device.deviceID, capability)) }
        }
        return offerings.keys.sorted().compactMap { name in
            guard let entries = offerings[name], let first = entries.first else { return nil }
            let ids = entries.map { $0.0 }.sorted()
            func targeted(_ schema: [String: Any], ids: [String], required: Bool) -> [String: Any] {
                var result = schema
                var props = result["properties"] as? [String: [String: Any]] ?? [:]
                props["device_id"] = ["type": "string", "enum": ids,
                    "description": "Target wearable. Required when multiple devices offer this action."]
                result["properties"] = props
                if required { result["required"] = Array(Set((result["required"] as? [String] ?? []) + ["device_id"])).sorted() }
                return result
            }
            let sameSchema = entries.allSatisfy { NSDictionary(dictionary: $0.1.inputSchema).isEqual(to: first.1.inputSchema) }
            let schema: [String: Any] = sameSchema
                ? targeted(first.1.inputSchema, ids: ids, required: ids.count > 1)
                : ["type": "object", "oneOf": entries.map { targeted($0.1.inputSchema, ids: [$0.0], required: true) }]
            return ["name": name, "description": first.1.description, "input_schema": schema]
        }
    }

    func notificationChannels() -> [NotificationChannelInfo] {
        var seen: Set<String> = []
        return devices.compactMap { $0.notificationChannel }.filter { seen.insert($0.key).inserted }
    }

    /// Route a notification to whichever device owns ``channelKey``.
    func forwardNotification(channel channelKey: String, title: String, body: String) {
        guard let device = devices.first(where: { $0.notificationChannel?.key == channelKey }) else { return }
        device.forwardNotification(title: title, body: body)
    }

    /// Routes a bridge invoke to the right device.
    func invoke(skill: String, args: [String: Any]) async throws -> [String: Any] {
        if args["device_id"] != nil, !(args["device_id"] is String) { throw DeviceError.badArgument("device_id must be a string") }
        let requested = args["device_id"] as? String
        let offersSkill = { (d: any WearableDevice) in d.capabilities.contains { $0.name == skill } }
        let target: (any WearableDevice)?
        if let requested {
            guard !requested.isEmpty, let device = device(id: requested), offersSkill(device) else {
                throw DeviceError.badArgument("Requested device does not offer \(skill)")
            }
            target = device
        } else {
            let candidates = devices.filter(offersSkill)
            guard candidates.count <= 1 else { throw DeviceError.badArgument("device_id is required when multiple devices offer this command") }
            target = candidates.first
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
