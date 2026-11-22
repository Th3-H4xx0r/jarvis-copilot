import Combine
import Foundation

/// The Ray-Ban Meta (Gen 2) glasses as a first-class `WearableDevice` — Jarvis's `meta_glasses_*`
/// tools. One code path for both glasses: `MetaGlassesHub` builds it over the simulator
/// (`SimulatedGlassesTransport`) while Sim is selected, and over the real BLE transport
/// (`MetaGlassesTransport`, hardware-gated) once the real glasses exist. Every call is logged to the
/// command feed with what the glasses did or why they refused.
@MainActor
final class MetaGlassesDevice: ObservableObject, WearableDevice {
    static let shared = MetaGlassesDevice()
    static let model = "Ray-Ban Meta (Gen 2)"

    /// Permanent defaults/identity key. Mirrors `WearableKind.metaGlasses.rawValue` — never rename.
    static let identityKey = WearableKind.metaGlasses.rawValue

    let transport: GlassesTransport
    let session: MetaGlassesSession
    let feed: MetaCommandFeed
    let deviceID: String

    init(transport: GlassesTransport = MetaGlassesTransport.shared,
         voice: MetaVoiceTurnController = VoiceStoreTurnController.shared,
         feed: MetaCommandFeed? = nil,
         defaults: UserDefaults = .standard) {
        self.transport = transport
        self.session = MetaGlassesSession(transport: transport, voice: voice)
        self.feed = feed ?? MetaCommandFeed.shared
        deviceID = WearableIdentity.remembered(Self.identityKey)
            ?? defaults.string(forKey: "meta.stableDeviceID")
            ?? "meta-glasses-\(UUID().uuidString)"
        defaults.set(deviceID, forKey: "meta.stableDeviceID")
    }

    var isConnected: Bool { session.isReady }

    /// The fixed `meta_*` catalogue (plan §6.1: never add/remove on link state — it thrashes the
    /// register frame and can push other wearables past the 512 cap).
    static let capabilityNames = ["meta_glasses_status", "meta_glasses_look", "meta_glasses_photo",
                                  "meta_glasses_video", "meta_glasses_live", "meta_glasses_speak",
                                  "meta_glasses_volume", "meta_glasses_talk", "meta_glasses_media",
                                  "meta_glasses_settings"]

    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(
                name: "meta_glasses_status",
                description: "Ray-Ban Meta glasses: battery, worn/folded, heat, storage, recording/streaming, volume.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "meta_glasses_look",
                description: "What the glasses camera can do now; while live streaming, returns the current frame to look at.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "meta_glasses_photo",
                description: "Take a photo with the glasses camera (what the wearer sees) for vision. Needs confirm=true.",
                inputSchema: DeviceCapability.schema([
                    "question": ["type": "string", "maxLength": 2000],
                    "confirm": ["type": "boolean"],
                ])),
            DeviceCapability(
                name: "meta_glasses_video",
                description: "Record a video clip with the glasses (capped by the glasses' clip length, max 180 s). Needs confirm=true.",
                inputSchema: DeviceCapability.schema([
                    "seconds": ["type": "integer", "minimum": 1, "maximum": 180],
                    "confirm": ["type": "boolean"],
                ])),
            DeviceCapability(
                name: "meta_glasses_live",
                description: "Start or stop the glasses' live video stream to the phone.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["start", "stop"]],
                ], required: ["action"])),
            DeviceCapability(
                name: "meta_glasses_speak",
                description: "Say text through the glasses' open-ear speakers.",
                inputSchema: DeviceCapability.schema([
                    "text": ["type": "string", "maxLength": 1000],
                ], required: ["text"])),
            DeviceCapability(
                name: "meta_glasses_volume",
                description: "Set the glasses' speaker volume (0-100).",
                inputSchema: DeviceCapability.schema([
                    "level": ["type": "integer", "minimum": 0, "maximum": 100],
                ], required: ["level"])),
            DeviceCapability(
                name: "meta_glasses_talk",
                description: "Open the glasses' assistant so the wearer can ask Jarvis something (for ring buttons and shortcuts).",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "meta_glasses_media",
                description: "Photos/videos taken with the glasses: list them, get the latest photo to look at, or import all to the phone's Photos.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["list", "latest_photo", "import"]],
                    "question": ["type": "string", "maxLength": 2000],
                ], required: ["action"])),
            DeviceCapability(
                name: "meta_glasses_settings",
                description: "Read or change the glasses' capture settings: clip length (30/60/180 s) and video mode.",
                inputSchema: DeviceCapability.schema([
                    "clip_length_seconds": ["type": "integer", "enum": MetaGen2Profile.clipLengths],
                    "video_mode": ["type": "string", "enum": MetaVideoMode.allCases.map(\.key)],
                ])),
        ]
    }

    func snapshot() -> [String: Any] {
        // Identical for the simulator and the real glasses: Jarvis sees one pair of glasses.
        var state: [String: Any] = [
            "model": Self.model,
            "device_id": deviceID,
            "connected": isConnected,
        ]
        state.merge(session.snapshot()) { _, new in new }
        if let hw = session.hardware { state.merge(Self.describe(hw)) { _, new in new } }
        return state
    }

    static func describe(_ hw: MetaHardwareState) -> [String: Any] {
        var out: [String: Any] = [
            "battery_percent": Int(hw.battery.rounded()),
            "charging": hw.charging,
            "case_battery_percent": Int(hw.caseBattery.rounded()),
            "worn": hw.worn,
            "folded": hw.folded,
            "in_case": hw.inCase,
            "in_range": hw.inRange,
            "capture_led_covered": hw.ledCovered,
            "heat": hw.heatLabel,
            "camera_too_hot": hw.cameraTooHot,
            "storage_free_gb": Double(hw.storageFree / 100_000_000) / 10,
            "photos_on_glasses": hw.photoCount,
            "videos_on_glasses": hw.videoCount,
            "volume": hw.volume,
            "video_mode": hw.videoMode.key,
            "clip_length_seconds": hw.clipLength,
            "streaming": hw.streaming,
            "music_playing": hw.musicPlaying,
        ]
        if let rec = hw.recording { out["recording_seconds"] = Int(rec.elapsed) }
        if let reason = hw.captureRefusal() { out["camera_unavailable_because"] = reason }
        return out
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            let result = try await perform(name, args: args)
            return result
        } catch {
            // The glasses' own refusals are already in the feed (the simulator logs them).
            if case MetaGlassesError.refused = error {} else {
                feed.log(.jarvis, name, detail: error.localizedDescription, outcome: .refused(error.localizedDescription))
            }
            throw error
        }
    }

    private func perform(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "meta_glasses_status":
            feed.log(.jarvis, "Status", outcome: .info)
            return snapshot()

        case "meta_glasses_look":
            var state = snapshot()
            if let frame = session.latestLiveFrame {
                feed.log(.jarvis, "Look (live frame)", thumbnail: SimulatedGlassesTransport.thumbnail(frame))
                state["base64"] = frame.base64EncodedString()
                state["mime"] = "image/jpeg"
                return state
            }
            let refusal = session.hardware?.captureRefusal()
            state["can_capture"] = session.isReady && refusal == nil
            state["hint"] = !session.isReady ? "The glasses link is not ready."
                : refusal ?? "Call meta_glasses_photo with confirm=true to see what the wearer sees."
            feed.log(.jarvis, "Look", detail: refusal, outcome: .info)
            return state

        case "meta_glasses_photo":
            guard (args["confirm"] as? Bool) == true else { throw MetaGlassesError.shutterConfirmationRequired }
            let question = args["question"] as? String
            let shot = try await session.capturePhoto(question: question)
            // Vision gets a ≤1440 px copy; the full 12 MP stays in glasses storage.
            let vision = SimulatedGlassesTransport.downscaled(shot.data, maxEdge: CGFloat(MetaGen2Profile.visionMaxEdge)) ?? shot.data
            var result: [String: Any] = [
                "base64": vision.base64EncodedString(),
                "mime": shot.mime,
                "bytes": vision.count,
                "full_resolution": "\(MetaGen2Profile.photoWidth)x\(MetaGen2Profile.photoHeight)",
                "saved_to": "glasses storage",
            ]
            if let question { result["question"] = question }
            return result

        case "meta_glasses_video":
            guard (args["confirm"] as? Bool) == true else { throw MetaGlassesError.shutterConfirmationRequired }
            let requested = (args["seconds"] as? Int) ?? (args["seconds"] as? Double).map { Int($0) }
            let seconds = max(1, min(requested ?? session.hardware?.clipLength ?? MetaGen2Profile.defaultClipLength, 180))
            let clip = try await session.recordVideo(seconds: seconds)
            var result: [String: Any] = [
                "seconds": Int(clip.seconds.rounded()),
                "mode": clip.mode.label,
                "resolution": "\(clip.mode.width)x\(clip.mode.height)",
                "bytes": clip.bytes,
                "saved_to": "glasses storage",
            ]
            if let reason = clip.stopReason { result["stopped_early"] = reason }
            if let cap = session.hardware?.clipLength, seconds > cap {
                result["note"] = "The glasses' clip length is \(cap) s, so the clip was capped."
            }
            return result

        case "meta_glasses_live":
            let action = (args["action"] as? String ?? "").lowercased()
            switch action {
            case "start":
                try await session.startLive()
                return ["streaming": true, "note": "Call meta_glasses_look to see the current frame."]
            case "stop":
                try await session.stopLive()
                return ["streaming": false]
            default:
                throw DeviceError.badArgument("action must be start or stop")
            }

        case "meta_glasses_speak":
            guard let text = args["text"] as? String, !text.isEmpty else { throw DeviceError.badArgument("text is required") }
            try await session.speak(text)
            return ["spoken": true]

        case "meta_glasses_talk":
            try await session.openAssistant()
            return ["listening": true, "note": "The glasses chimed and are listening for the question."]

        case "meta_glasses_media":
            let action = (args["action"] as? String ?? "").lowercased()
            switch action {
            case "list":
                let items = try await session.listMedia()
                let iso = ISO8601DateFormatter()
                func row(_ item: MetaStoredMedia) -> [String: Any] {
                    var out: [String: Any] = ["kind": item.kind.rawValue, "taken_at": iso.string(from: item.date)]
                    if let seconds = item.seconds { out["seconds"] = Int(seconds.rounded()) }
                    if let mode = item.mode { out["video_mode"] = mode.key }
                    if item.savedToPhotos { out["in_photos_library"] = true }
                    return out
                }
                return [
                    "on_glasses": items.filter { !$0.onPhone }.prefix(50).map(row),
                    "on_phone": items.filter(\.onPhone).prefix(50).map(row),
                ]
            case "latest_photo":
                guard let photo = try await session.latestPhoto() else {
                    return ["found": false, "note": "No photos taken with the glasses yet."]
                }
                let vision = SimulatedGlassesTransport.downscaled(photo.data, maxEdge: CGFloat(MetaGen2Profile.visionMaxEdge)) ?? photo.data
                var result: [String: Any] = [
                    "base64": vision.base64EncodedString(),
                    "mime": "image/jpeg",
                    "taken_at": ISO8601DateFormatter().string(from: photo.date),
                    "was_on_glasses": photo.onGlasses,
                ]
                if let question = args["question"] as? String { result["question"] = question }
                return result
            case "import":
                let done = try await session.importMedia()
                var result: [String: Any] = ["imported": done.imported, "saved_to_photos": done.savedToPhotos]
                if let problem = done.problem { result["note"] = problem }
                if done.imported == 0, done.problem == nil { result["note"] = "Nothing new on the glasses." }
                return result
            default:
                throw DeviceError.badArgument("action must be list, latest_photo or import")
            }

        case "meta_glasses_settings":
            if let seconds = (args["clip_length_seconds"] as? Int) ?? (args["clip_length_seconds"] as? Double).map({ Int($0) }) {
                try await session.setClipLength(seconds)
            }
            if let key = args["video_mode"] as? String {
                guard let mode = MetaVideoMode(key: key) else {
                    throw DeviceError.badArgument("video_mode must be one of \(MetaVideoMode.allCases.map(\.key).joined(separator: ", "))")
                }
                try await session.setVideoMode(mode)
            }
            let hw = session.hardware
            return [
                "clip_length_seconds": hw?.clipLength ?? MetaGen2Profile.defaultClipLength,
                "video_mode": hw?.videoMode.key ?? MetaVideoMode.uhd3K30.key,
                "clip_lengths": MetaGen2Profile.clipLengths,
                "video_modes": MetaVideoMode.allCases.map(\.key),
            ]

        case "meta_glasses_volume":
            guard let level = (args["level"] as? Int) ?? (args["level"] as? Double).map({ Int($0) }) else {
                throw DeviceError.badArgument("level (0-100) is required")
            }
            try await session.setVolume(level)
            return ["volume": max(0, min(level, 100))]

        default:
            throw DeviceError.unknownCommand(name)
        }
    }
}
