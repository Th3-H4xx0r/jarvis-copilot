import Combine
import Foundation

/// The Ray-Ban Meta (Gen 2) glasses as a first-class `WearableDevice`.
///
/// RUNTIME-INERT. The device/session/turn LOGIC below is fully implemented against the
/// `GlassesTransport` abstraction and is exercised end-to-end by `SimulatedGlassesTransport` in
/// tests, but it is **not** installed by `WearablesHub`, registered with `DeviceRegistry`, or
/// shown in any UI — so the agent never sees these `meta_*` skills and nothing here runs on a
/// user's phone. The real BLE + AirShield transport (`MetaGlassesTransport`) and the change-owner
/// flow are hardware-gated skeletons. See `docs/glasses/2026-11-21-meta-glasses-protocol-plan.md`
/// (§6). Mirrors the shape of `Glasses/Features/InmoGo3Device.swift`.
@MainActor
final class MetaGlassesDevice: ObservableObject, WearableDevice {
    static let shared = MetaGlassesDevice()
    static let model = "Ray-Ban Meta (Gen 2)"

    /// Permanent defaults/identity key. Mirrors `WearableKind.metaGlasses.rawValue` — never rename.
    static let identityKey = WearableKind.metaGlasses.rawValue

    /// The link transport (the real skeleton by default; the simulator is injected in tests).
    let transport: GlassesTransport
    /// The session that owns the wake→turn→reply→close lifecycle and photo/touch handling.
    let session: MetaGlassesSession

    let deviceID: String

    init(transport: GlassesTransport = MetaGlassesTransport.shared,
         voice: MetaVoiceTurnController = VoiceStoreTurnController.shared,
         defaults: UserDefaults = .standard) {
        self.transport = transport
        self.session = MetaGlassesSession(transport: transport, voice: voice)
        deviceID = WearableIdentity.remembered(Self.identityKey)
            ?? defaults.string(forKey: "meta.stableDeviceID")
            ?? "meta-glasses-\(UUID().uuidString)"
        defaults.set(deviceID, forKey: "meta.stableDeviceID")
    }

    /// True only when the session's link is up and trusted. False throughout production (the
    /// real transport is never started) and false in tests until `session.start()` runs.
    var isConnected: Bool { session.isReady }

    /// A fixed, small `meta_*` catalogue (plan §6.1: never add/remove on link state — it thrashes
    /// the ~85 KB register frame and can push other wearables past the 512 cap). Never reaches the
    /// agent in production because the device is never registered.
    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(
                name: "meta_glasses_status",
                description: "Read Ray-Ban Meta link, trust and turn state.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "meta_glasses_look",
                description: "Report whether the glasses can capture now and how to.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "meta_glasses_photo",
                description: "Capture a photo from the glasses for vision. Needs confirm=true.",
                inputSchema: DeviceCapability.schema([
                    "question": ["type": "string", "maxLength": 2000],
                    "confirm": ["type": "boolean"],
                ])),
        ]
    }

    func snapshot() -> [String: Any] {
        var state: [String: Any] = [
            "model": Self.model,
            "device_id": deviceID,
            "connected": isConnected,
            "implemented": false,
            "note": "Logic implemented against a transport abstraction; real BLE+AirShield is a hardware-gated skeleton.",
        ]
        state.merge(session.snapshot()) { _, new in new }
        return state
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "meta_glasses_status":
            return snapshot()
        case "meta_glasses_look":
            var state = snapshot()
            state["can_capture"] = session.isReady
            state["hint"] = session.isReady
                ? "Call meta_glasses_photo with confirm=true to capture and analyze a still."
                : "Glasses link is not ready."
            return state
        case "meta_glasses_photo":
            // Shutter confirm (plan §6.2 trust rule): the LED stays on, never defeated.
            guard (args["confirm"] as? Bool) == true else {
                throw MetaGlassesError.shutterConfirmationRequired
            }
            let question = args["question"] as? String
            let shot = try await session.capturePhoto(question: question)
            var result: [String: Any] = [
                "base64": shot.data.base64EncodedString(),
                "mime": shot.mime,
                "bytes": shot.data.count,
            ]
            if let question { result["question"] = question }
            return result
        default:
            throw DeviceError.unknownCommand(name)
        }
    }
}
