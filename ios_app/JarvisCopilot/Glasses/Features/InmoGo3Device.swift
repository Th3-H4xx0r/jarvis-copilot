import Combine
import CoreFoundation
import Foundation

/// One command implementation shared by the detail page, chat and bridge.
@MainActor
final class InmoGo3Device: ObservableObject, WearableDevice {
    static let shared = InmoGo3Device()
    static let model = "INMO GO3"
    let session: InmoSession
    let history: InmoBatteryHistory
    let deviceID: String
    @Published private(set) var recentResult: String?
    @Published var experimentalEnabled: Bool {
        didSet { UserDefaults.standard.set(experimentalEnabled, forKey: "inmo.experimentalControls"); BridgeClient.shared.sendRegistration() }
    }
    private var observations = Set<AnyCancellable>()
    private var eventObserver: UUID?
    private var cameraMode: Int?
    /// Feature owners attach handlers here; unsupported features never claim success.
    var featureHandlers: [String: ([String: Any]) async throws -> [String: Any]] = [:]

    init(session: InmoSession = .shared, identity: String? = nil, defaults: UserDefaults = .standard) {
        self.session = session
        deviceID = identity ?? WearableIdentity.remembered(WearableKeepAlive.glasses) ?? defaults.string(forKey: "inmo.stableDeviceID") ?? "inmo-go3-\(UUID().uuidString)"
        defaults.set(deviceID, forKey: "inmo.stableDeviceID")
        history = InmoBatteryHistory(identity: deviceID, defaults: defaults)
        experimentalEnabled = defaults.bool(forKey: "inmo.experimentalControls")
        session.$status.sink { [weak self] status in
            guard let self else { return }

            self.objectWillChange.send()
        }.store(in: &observations)
        session.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            if state == .ready { self.history.connected() } else { self.history.disconnected() }
            self.objectWillChange.send()
            Task { @MainActor in BridgeClient.shared.sendRegistration() }
        }.store(in: &observations)
        eventObserver = session.addEventObserver { [weak self] event in
            guard let self, case let .message(type, fields, _) = event, type == 20,
                  let values = try? fields.firstField(23)?.nested(),
                  let battery = try? values.firstField(8)?.nested() else { return }
            let rawValue = battery.firstField(1)?.varint ?? 0
            guard rawValue <= 100 else { return }
            self.history.record(Int(rawValue))
            self.objectWillChange.send()
        }
    }
    var notificationChannel: NotificationChannelInfo? {
        .init(key: "glasses", label: "Glasses", symbol: "eyeglasses", defaultOn: false)
    }
    func forwardNotification(title: String, body: String) {
        session.forwardNotification(title: title, body: body)
    }
    var isConnected: Bool { session.isReady }
    func refreshMembership() {
        DeviceRegistry.shared.syncMembership(of: self, identity: "inmoGo3Control", model: Self.model)
    }
    struct InventoryEntry: Identifiable {
        let id: String
        let group: String
        let title: String
        let skill: String?
        let evidence: String
        let reason: String?
    }
    static let inventory: [InventoryEntry] = [
        .init(id: "remote", group: "Phone remote", title: "Tap, directional drag, Home and Back", skill: "glasses_touch", evidence: "Observed closing Home/Back/tap/drag trials", reason: nil),
        .init(id: "go", group: "Phone remote", title: "GO, menu, long Home and double tap", skill: "glasses_remote_key", evidence: "Source command variants", reason: nil),
        .init(id: "display", group: "Display", title: "Brightness and screen timeout", skill: "glasses_set_brightness", evidence: "Observed brightness and 15/30-second selectors", reason: nil),
        .init(id: "illumination", group: "Display", title: "Automatic illumination", skill: "glasses_settings", evidence: "Source GLASSES_SETTINGS type 0", reason: nil),
        .init(id: "font", group: "Display", title: "Screen wake/sleep, font and language", skill: nil, evidence: "Source settings and reported font", reason: "Explicit model support and independent device validation pending"),
        .init(id: "sound", group: "Sound", title: "Volume and system sounds", skill: "glasses_set_volume", evidence: "Observed volume; source system sounds", reason: nil),
        .init(id: "music", group: "Sound", title: "Music and call/audio controls", skill: nil, evidence: "Source CONTROL_MUSIC", reason: "Phone media/call integration and model support pending"),
        .init(id: "input", group: "Input", title: "Wear detection and voice wake", skill: "glasses_settings", evidence: "Source settings types 2 and 21", reason: nil),
        .init(id: "gestures", group: "Input", title: "Touch enable, GO shortcut and gesture assignments", skill: nil, evidence: "Source long GO shortcut and input screens", reason: "Shortcut mapping and model capability validation pending"),
        .init(id: "notifications", group: "Notifications", title: "DND, indicator light and iOS ANCS", skill: "glasses_settings", evidence: "Observed DND; source indicator/ANCS", reason: nil),
        .init(id: "notificationApps", group: "Notifications", title: "Circulation, broadcast and per-app selections", skill: nil, evidence: "Source notification screens", reason: "iOS notification service and permission integration pending"),
        .init(id: "setup", group: "Device setup", title: "Device name and time/timezone", skill: "glasses_device_setting", evidence: "Source settings; experimental local enablement", reason: nil),
        .init(id: "setupApps", group: "Device setup", title: "Operation guide, app visibility and app order", skill: nil, evidence: "Source setup screens", reason: "Model support and supported-app selection validation pending"),
        .init(id: "prompt", group: "Teleprompter", title: "Editor, upload, start, stop, previous/next and position", skill: "glasses_teleprompter_upload", evidence: "Observed BT-170/171", reason: nil),
        .init(id: "promptModes", group: "Teleprompter", title: "Automatic/voice page mode, speed and ring/GO mode", skill: nil, evidence: "Observed auto-page packet; source modes", reason: "Physical behavior and additional modes require device trial"),
        .init(id: "ai", group: "Jarvis AI", title: "Wake/button, microphone, transcript, answer, speech and cancel", skill: "glasses_show_answer", evidence: "Observed AI messages and proprietary audio", reason: nil),
        .init(id: "vision", group: "Jarvis AI", title: "Vision capture and image acknowledgement", skill: nil, evidence: "Source AiPhoto command", reason: "Image pipeline and device capability validation pending"),
        .init(id: "camera", group: "Camera and gallery", title: "Photo/video pages and close", skill: "glasses_camera_open", evidence: "Observed BT-080/090", reason: nil),
        .init(id: "shutter", group: "Camera and gallery", title: "Shutter and recording start/stop", skill: "glasses_camera_action", evidence: "Source CameraCommand 5/6/7", reason: nil),
        .init(id: "gallery", group: "Camera and gallery", title: "Inventory, Wi-Fi sync, progress, cancel and export", skill: "glasses_media_list", evidence: "Observed paired BT/Wi-Fi checksums", reason: nil),
        .init(id: "galleryOther", group: "Camera and gallery", title: "Screenshot, thumbnails and selected deletion", skill: nil, evidence: "Source gallery/UI", reason: "Screenshot shortcut identity and safe selected-deletion response pending"),
        .init(id: "translation", group: "Language", title: "Translation modes, languages, subtitles and speech", skill: nil, evidence: "Source translation/subtitle modules", reason: "Phone translation service, model support and end-to-end validation pending"),
        .init(id: "notes", group: "Notes and recording", title: "Recorder/notes, pause/resume/stop, attachments, list and export", skill: nil, evidence: "Source recorder and speed-note modules", reason: "Recording lifecycle and saved-item service integration pending"),
        .init(id: "navigation", group: "Navigation and modules", title: "Route preview/start/cancel, guidance, scenic guide and assistant", skill: nil, evidence: "Source modules", reason: "Phone navigation/services must exist before activation"),
        .init(id: "maintenance", group: "System maintenance", title: "Versions, diagnostics, disconnect and local forget", skill: "glasses_status", evidence: "Observed status plus iOS connection diagnostics", reason: nil),
        .init(id: "restricted", group: "System maintenance", title: "Power off, factory reset, unbind and firmware installation", skill: nil, evidence: "Source vendor maintenance", reason: "Outside ordinary automation; intentionally unavailable"),
    ]
    var capabilities: [DeviceCapability] {
        func command(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], _ required: [String] = []) -> DeviceCapability {
            DeviceCapability(name: name, description: description, inputSchema: DeviceCapability.schema(properties, required: required))
        }
        let percent: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 100]
        let text: [String: Any] = ["type": "string", "maxLength": 32768]
        var list = [command("glasses_status", "Read GO3 control/audio readiness and reported status; missing values remain unknown."), command("glasses_capabilities", "Read the full INMO parity inventory, evidence and unavailable reasons."), command("glasses_battery_history", "Read local glasses battery observations and labeled recent-use estimates.", ["hours": ["type": "integer", "minimum": 1, "maximum": 168]]), command("glasses_home", "Return Home. Result sent does not imply an acknowledgement."), command("glasses_back", "Press Back. Module-specific state is not a generic acknowledgement."), command("glasses_touch", "Tap or finish one directional drag on the glasses.", ["kind": ["type": "string", "enum": ["click", "drag"]], "direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "x": percent, "y": percent], ["kind", "x", "y"]), command("glasses_set_brightness", "Set display brightness 0–100.", ["value": percent], ["value"]), command("glasses_set_volume", "Set glasses volume 0–100; phone output volume can follow.", ["value": percent], ["value"]), command("glasses_set_dnd", "Set Do Not Disturb.", ["enabled": ["type": "boolean"]], ["enabled"]), command("glasses_set_screen_timeout", "Set validated screen timeout selector.", ["seconds": ["type": "integer", "enum": [15, 30]]], ["seconds"]), command("glasses_settings", "List settings or set a locally enabled source-derived boolean setting.", ["setting": ["type": "string", "enum": Array(Self.settings.keys).sorted()], "enabled": ["type": "boolean"]]), command("glasses_open_module", "Open a supported named module; service-dependent modules are unavailable.", ["module": ["type": "string", "enum": ["teleprompter", "ai", "camera"]]], ["module"]), command("glasses_close_module", "Close a supported named module.", ["module": ["type": "string", "enum": ["teleprompter", "ai", "camera"]]], ["module"])]
        for (name, description) in [("glasses_camera_open", "Open photo page; this is not shutter."), ("glasses_video_open", "Open video page; this does not start recording."), ("glasses_camera_close", "Close camera/video page."), ("glasses_media_list", "Read media inventory."), ("glasses_media_cancel", "Cancel current media transfer."), ("glasses_teleprompter_start", "Start the acknowledged uploaded document."), ("glasses_teleprompter_stop", "Stop teleprompter and close its module.")] { list.append(command(name, description)) }
        list += [command("glasses_media_download", "Download a selected inventory item and return an app-local artifact.", ["id": ["type": "string"]], ["id"]), command("glasses_teleprompter_upload", "Upload original text with observed document checksum convention.", ["text": text, "title": ["type": "string"]], ["text"]), command("glasses_teleprompter_page", "Previous or next teleprompter page.", ["direction": ["type": "string", "enum": ["previous", "next"]]], ["direction"]), command("glasses_teleprompter_progress", "Synchronize independent line and percentage positions.", ["line": ["type": "integer", "minimum": 1], "percent": ["type": "number", "minimum": 0, "maximum": 100]], ["line"]), command("glasses_show_transcription", "Show partial or final Jarvis transcription.", ["text": text, "final": ["type": "boolean"]], ["text"]), command("glasses_show_answer", "Show Jarvis answer text and state.", ["text": text, "final": ["type": "boolean"]], ["text"])]
        if experimentalEnabled { list.append(command("glasses_camera_action", "Experimental source-derived shutter/start/stop; device verification pending.", ["action": ["type": "string", "enum": ["shutter", "start_recording", "stop_recording"]]], ["action"])) }
        if experimentalEnabled { list += InmoAdvancedControls.capabilities }
        return list
    }
    static let settings: [String: Int] = ["automatic_illumination": 0, "wear_detection": 2, "system_sounds": 3, "voice_wake": 21, "indicator_light": 22, "ios_ancs": 24]
    func inventorySnapshot() -> [[String: Any]] {
        Self.inventory.map { entry in
            let featureMissing = entry.skill.map { $0.hasPrefix("glasses_teleprompter") && featureHandlers[$0] == nil } ?? false
            let sourceOnly = ["illumination", "input", "shutter", "go", "setup"].contains(entry.id)
            let reason = entry.reason ?? (featureMissing ? "Feature is not initialized" : sourceOnly && !experimentalEnabled ? "Enable experimental controls locally; source-derived, not device-verified" : !isConnected && !["maintenance"].contains(entry.id) ? "Connect control channel first" : nil)
            return ["id": entry.id, "group": entry.group, "title": entry.title, "skill": entry.skill as Any? ?? NSNull(), "evidence": entry.evidence, "available": reason == nil, "reason": reason as Any? ?? NSNull()]
        }
    }
    func snapshot() -> [String: Any] {
        let state = session.status
        let route = GlassesAudioLink.shared.state
        return ["device_id": deviceID, "model": state.model as Any? ?? Self.model, "name": InmoGo3.name, "connected": isConnected, "control_state": String(describing: session.state), "audio_connected": route.connected, "audio_output_glasses": route.speakers, "audio_input_glasses": route.microphone, "battery": state.battery as Any? ?? NSNull(), "brightness": state.brightness as Any? ?? NSNull(), "volume": state.volume as Any? ?? NSNull(), "dnd": state.dnd as Any? ?? NSNull(), "firmware": state.firmware as Any? ?? NSNull(), "module": state.module as Any? ?? NSNull(), "screen_timeout_seconds": state.screenTimeoutSelector.flatMap { [0: 15, 1: 30][$0] } as Any? ?? NSNull(), "rssi": session.rssi as Any? ?? NSNull(), "protocol_counters": ["valid_frames": session.counters.validFrames, "invalid_frames": session.counters.invalidFrames, "expired_assemblies": session.counters.expiredAssemblies], "observed_at": state.lastReceived.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "stale": !isConnected || state.lastReceived.map { Date().timeIntervalSince($0) > 300 } ?? true, "missing_value_reason": "Not reported by a validated device response", "battery_history": history.snapshot(), "capabilities": inventorySnapshot(), "media": InmoMediaTransfer.shared.snapshot(), "last_error": session.lastError as Any? ?? NSNull(), "recent_command_result": recentResult as Any? ?? NSNull()]
    }
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        if name == "glasses_status" { return snapshot() }
        if name == "glasses_capabilities" { return ["inventory": inventorySnapshot(), "experimental_enabled": experimentalEnabled] }
        if name == "glasses_battery_history" {
            let hours = try integer(args, "hours", range: 1...168, defaultValue: 24)
            return history.snapshot(since: Date().addingTimeInterval(-Double(hours) * 3600))
        }
        if name == "glasses_settings", args["setting"] == nil { return ["settings": Self.settings.keys.sorted(), "experimental_enabled": experimentalEnabled, "evidence": "Source-derived; local opt-in required"] }
        guard isConnected else { throw DeviceError.notConnected }
        if let handler = featureHandlers[name] { return try await handler(args) }
        var bytes: Data
        switch name {
        case "glasses_home": bytes = InmoCommand.home()
        case "glasses_back": bytes = InmoCommand.back()
        case "glasses_set_brightness": bytes = try InmoCommand.brightness(integer(args, "value", range: 0...100))
        case "glasses_set_volume": bytes = try InmoCommand.volume(integer(args, "value", range: 0...100))
        case "glasses_set_dnd": bytes = InmoCommand.dnd(try boolean(args, "enabled"))
        case "glasses_set_screen_timeout":
            let seconds = try integer(args, "seconds", range: 15...30)
            guard [15, 30].contains(seconds) else { throw DeviceError.badArgument("seconds must be 15 or 30") }
            bytes = try InmoCommand.screenTimeout(seconds: seconds)
        case "glasses_touch":
            guard let kind = args["kind"] as? String, ["click", "drag"].contains(kind) else { throw DeviceError.badArgument("kind must be click or drag") }
            var direction: Int?
            if kind == "drag" {
                guard let value = args["direction"] as? String, let mapped = ["up": 0, "down": 1, "left": 2, "right": 3][value] else { throw DeviceError.badArgument("drag requires direction") }
                direction = mapped
            }
            bytes = try InmoCommand.touch(kind: kind == "click" ? 1 : 2, direction: direction, x: integer(args, "x", range: 0...100), y: integer(args, "y", range: 0...100))
        case "glasses_settings":
            guard experimentalEnabled else { throw DeviceError.badArgument("Enable experimental controls locally before source-derived settings") }
            guard let setting = args["setting"] as? String, let type = Self.settings[setting] else { throw DeviceError.badArgument("Unsupported setting") }
            bytes = InmoCommand.settings(type: type, field: 2, value: try boolean(args, "enabled") ? 1 : 0)
        case "glasses_open_module", "glasses_close_module":
            guard let module = args["module"] as? String, let code = ["teleprompter": 2, "ai": 4, "camera": 11][module] else { throw DeviceError.badArgument("Unsupported module; phone-side services must be available") }
            bytes = name == "glasses_open_module" ? InmoCommand.openModule(code) : InmoCommand.closeModule(code)
        case "glasses_camera_open": cameraMode = 0; bytes = InmoCommand.envelope(type: 14, field: 17, payload: Data([0x10, 0x00]))
        case "glasses_video_open": cameraMode = 1; bytes = InmoCommand.envelope(type: 14, field: 17, payload: Data([0x10, 0x01]))
        case "glasses_camera_close":
            guard let mode = cameraMode else { throw DeviceError.badArgument("Camera mode unknown; open a photo/video page in Jarvis before closing") }
            bytes = InmoCommand.envelope(type: 14, field: 17, payload: Data([0x10, mode == 1 ? 0x03 : 0x02])); cameraMode = nil
        case "glasses_camera_action":
            guard experimentalEnabled, let action = args["action"] as? String, let code = ["shutter": 5, "start_recording": 6, "stop_recording": 7][action] else { throw DeviceError.badArgument("Source-derived camera actions require local experimental enablement") }
            bytes = InmoCommand.envelope(type: 14, field: 17, payload: Data([0x10, UInt8(code)]))
        case "glasses_media_list": try await InmoMediaTransfer.shared.refresh(); return InmoMediaTransfer.shared.snapshot()
        case "glasses_media_download":
            guard let id = args["id"] as? String else { throw DeviceError.badArgument("id is required") }
            let url = try await InmoMediaTransfer.shared.download(id: id)
            return ["state": "confirmed", "artifact": url.lastPathComponent, "local_url": url.absoluteString]
        case "glasses_media_cancel": InmoMediaTransfer.shared.cancel(); return ["state": "cancelled"]
        default: throw DeviceError.badArgument("\(name) is not initialized or supported; inspect glasses_capabilities")
        }
        try await session.send(bytes)
        recentResult = "\(name): sent · awaiting device state"
        return ["state": "sent", "command": name, "confirmed": false, "requested": args, "observed": snapshot()]
    }
    private func integer(_ args: [String: Any], _ key: String, range: ClosedRange<Int>, defaultValue: Int? = nil) throws -> Int {
        let value: Int
        if args[key] == nil, let defaultValue { value = defaultValue }
        else {
            guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue else { throw DeviceError.badArgument("\(key) must be an integer") }
            value = number.intValue
        }
        guard range.contains(value) else { throw DeviceError.badArgument("\(key) must be \(range.lowerBound)–\(range.upperBound)") }
        return value
    }
    private func boolean(_ args: [String: Any], _ key: String) throws -> Bool {
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw DeviceError.badArgument("\(key) must be a boolean") }
        return value.boolValue
    }
}
