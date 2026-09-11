import Foundation

/// The wearables hub itself, exposed to Jarvis as one more `WearableDevice`.
///
/// Every other device's skills are only advertised while its Bluetooth link is up,
/// which left the agent with no way back: asked for the bottle while the bottle was
/// out of range, it had no `bottle_*` tool to call and nothing that could go and
/// find one. These three are always registered, so "scan, connect, then see what's
/// available" is a route the model can actually take.
///
/// Modelled on `PhoneDevice`: a fixed id, always connected, riding the existing
/// `DeviceRegistry` plumbing with no change to `BridgeClient`.
@MainActor
final class WearablesDevice: WearableDevice {
    static let model = "Jarvis Wearables"

    /// Fixed: there is one hub, and `DeviceRegistry.register` dedupes on this.
    let deviceID = "wearables"

    /// Always true — the hub is this app, not something we can lose the link to.
    var isConnected: Bool { true }

    private var hub: WearablesHub { .shared }

    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(
                name: "wearables_list",
                description: """
                    List every paired Jarvis wearable — bottle, scale, smart ring, ESP32 board — \
                    with whether each is currently connected, its signal, when it was \
                    last seen, and the commands it offers. Call this first when a \
                    device command fails or when you are not sure what is reachable.
                    """,
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "wearables_scan",
                description: """
                    Scan over Bluetooth for paired wearables and return what is nearby \
                    with signal strength. Use when a device is not responding, before \
                    wearables_connect.
                    """,
                inputSchema: DeviceCapability.schema([
                    "seconds": ["type": "integer",
                                "description": "How long to scan, 3–15. Defaults to 6."],
                ])),
            DeviceCapability(
                name: "wearables_connect",
                description: """
                    Bring a paired wearable's Bluetooth link up so its commands work. \
                    Only devices already paired in the app can be connected. Returns the \
                    resulting state; a device that is off or out of range comes back \
                    connected=false rather than failing.
                    """,
                inputSchema: DeviceCapability.schema([
                    "wearable_id": ["type": "string",
                                    "description": "device_id from wearables_list or wearables_scan."],
                ], required: ["wearable_id"])),
        ]
    }

    func snapshot() -> [String: Any] {
        ["model": Self.model,
         "bluetooth_ready": hub.bottle.bluetoothReady,
         "devices": hub.roster().map(\.json)]
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "wearables_list":
            return listing()

        case "wearables_scan":
            let raw = args["seconds"] as? Int ?? 6
            guard (3...15).contains(raw) else {
                throw DeviceError.badArgument("'seconds' must be an integer 3–15")
            }
            guard hub.bottle.bluetoothReady else {
                // Distinguishable from "the device is gone", so the agent can tell the
                // user to turn Bluetooth on instead of reporting a missing bottle.
                return ["bluetooth_ready": false, "devices": [], "scanned_seconds": 0]
            }
            let found = await hub.scan(seconds: TimeInterval(raw))
            return ["bluetooth_ready": true,
                    "scanned_seconds": raw,
                    "devices": found.map(\.json)]

        case "wearables_connect":
            // Named `wearable_id`, not `device_id`: the bridge injects a `device_id`
            // property into every skill's schema to pick between devices offering the
            // same command, and reusing it here would read as "run this on the bottle".
            guard let wanted = (args["wearable_id"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !wanted.isEmpty else {
                throw DeviceError.badArgument("'wearable_id' is required")
            }
            let roster = hub.roster()
            guard let entry = roster.first(where: { $0.deviceID == wanted }) else {
                throw DeviceError.badArgument(
                    "'\(wanted)' is not a paired device. Pair it in the Jarvis app first. "
                    + "Paired: \(roster.map(\.deviceID).joined(separator: ", "))")
            }
            guard hub.bottle.bluetoothReady else {
                return ["connected": false, "reason": "bluetooth is off", "bluetooth_ready": false]
            }
            let ok = await hub.connect(deviceID: entry.deviceID)
            var out: [String: Any] = ["connected": ok, "device_id": entry.deviceID]
            if !ok { out["reason"] = "not found — it may be off or out of range" }
            // Re-read so the caller sees post-connect state, matching how the bottle
            // skills return the state AFTER the change.
            out["devices"] = hub.roster().map(\.json)
            return out

        default:
            throw DeviceError.unknownCommand(name)
        }
    }

    /// Paired devices plus the commands each one offers, so one call answers both
    /// "what is here" and "what can I call on it".
    private func listing() -> [String: Any] {
        let registry = DeviceRegistry.shared
        let devices = hub.roster().map { entry -> [String: Any] in
            var row = entry.json
            row["commands"] = registry.device(id: entry.deviceID)?.capabilities.map(\.name) ?? []
            return row
        }
        return ["bluetooth_ready": hub.bottle.bluetoothReady, "devices": devices]
    }
}
