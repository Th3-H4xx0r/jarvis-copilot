import Foundation

@MainActor
final class Esf551Scale: WearableDevice {
    static let model = "Etekcity ESF551"
    private unowned let manager: ScaleManager
    init(manager: ScaleManager) { self.manager = manager }
    var deviceID: String { manager.connected?.id.uuidString ?? "esf551" }
    var isConnected: Bool { if case .ready = manager.state { return true }; return false }
    var capabilities: [DeviceCapability] { [
        DeviceCapability(name: "scale_get_reading", description: "Get the latest ESF551 weight and available body-composition estimates.", inputSchema: DeviceCapability.schema()),
        DeviceCapability(name: "scale_get_history", description: "Get recent locally stored ESF551 readings.", inputSchema: DeviceCapability.schema(["limit": ["type": "integer"]])),
    ] }
    func snapshot() -> [String: Any] {
        let reading = manager.latestObservation
        return ["weight_kg": reading?.weightKg as Any, "impedance_ohms": reading?.impedanceOhms as Any,
                "stable": reading?.isStable as Any, "connected": isConnected]
    }
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "scale_get_reading": return snapshot()
        case "scale_get_history":
            let limit = max(1, min(args["limit"] as? Int ?? 10, 50))
            return ["readings": ScaleHistoryStore.shared.readings.prefix(limit).map { ["date": $0.date.ISO8601Format(), "weight_kg": $0.weightKg, "metrics": $0.metrics.mapValues { $0 }] }]
        default: throw DeviceError.unknownCommand(name)
        }
    }
}
