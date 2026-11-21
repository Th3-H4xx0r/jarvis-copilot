import Foundation

/// One rule for "are the PC's lights Jarvis's to show right now": the Lighting section, the 3D model's
/// glow and the Wearables card all use it, so they never disagree.
enum PcLightingAvailability: Equatable {
    case live
    case setUp
    case unavailable(String)

    static func status(online: Bool, awake: Bool, mapped: Bool, engine: String?, engineError: String?,
                       controllers: Int) -> PcLightingAvailability {
        guard online, awake else { return .unavailable("The PC is asleep or offline") }
        if engine == "error" { return .unavailable(engineError ?? "OpenRGB isn't running on the PC") }
        if engine == "stopped" { return .unavailable("PC Lighting is switched off") }
        guard mapped, controllers > 0 else { return .setUp }
        return .live
    }
}

extension PcStore {
    func availability(awake: Bool) -> PcLightingAvailability {
        .status(online: online, awake: awake, mapped: isMapped, engine: engine, engineError: engineError,
                controllers: controllers.count)
    }
}
