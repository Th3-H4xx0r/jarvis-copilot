import Foundation

/// Exposes the S1 Pro's reverse-engineered command set as a `WearableDevice`.
///
/// Every command here maps to an opcode recovered from the stock app — see
/// `PROTOCOL.md`. This is a mapping layer: `BottleProtocol.swift` already owns the
/// wire format.
@MainActor
final class VsitooS1Pro: WearableDevice {
    static let model = "VSITOO S1 Pro"

    private unowned let manager: BottleManager

    init(manager: BottleManager) {
        self.manager = manager
    }

    /// The MAC, once the bottle has reported it (`10` response). Before that we fall
    /// back to the CoreBluetooth identifier, which is stable per install but not
    /// across reinstalls.
    var deviceID: String {
        manager.macAddress ?? manager.connected?.id.uuidString ?? "unpaired"
    }

    var isConnected: Bool { manager.state == .ready }

    // MARK: Catalogue

    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(
                name: "bottle_get_status",
                description: "Read the bottle's live state: water temperature, battery, "
                           + "charging, sterilising state and progress, cycle count, UV "
                           + "intensity, touch lock, screen timeout.",
                inputSchema: DeviceCapability.schema()),

            DeviceCapability(
                name: "bottle_sterilise",
                description: "Start or stop a UV-C sterilisation cycle. Starting one runs "
                           + "the lamp and uses meaningful battery, so `confirm` must be "
                           + "true to start.",
                inputSchema: DeviceCapability.schema([
                    "on": ["type": "boolean", "description": "true to start, false to stop"],
                    "confirm": ["type": "boolean",
                                "description": "Must be true to start a cycle. Not needed to stop."],
                ], required: ["on"])),

            DeviceCapability(
                name: "bottle_set_uv_intensity",
                description: "Set UV lamp power. 'strong' sterilises harder but costs "
                           + "noticeably more battery per cycle.",
                inputSchema: DeviceCapability.schema([
                    "level": ["type": "string", "enum": ["normal", "strong"]],
                ], required: ["level"])),

            DeviceCapability(
                name: "bottle_auto_clean",
                description: "Enable or disable the scheduled daily auto-sterilise.",
                inputSchema: DeviceCapability.schema([
                    "on": ["type": "boolean"],
                ], required: ["on"])),

            DeviceCapability(
                name: "bottle_touch_lock",
                description: "Lock or unlock the lid's touch screen. While locked the "
                           + "display won't wake to show temperature.",
                inputSchema: DeviceCapability.schema([
                    "on": ["type": "boolean"],
                ], required: ["on"])),

            DeviceCapability(
                name: "bottle_reminders",
                description: "Enable or disable the drink-reminder alerts on the bottle.",
                inputSchema: DeviceCapability.schema([
                    "on": ["type": "boolean"],
                ], required: ["on"])),

            DeviceCapability(
                name: "bottle_set_screen_seconds",
                description: "How long the lid display stays awake, 3–15 seconds.",
                inputSchema: DeviceCapability.schema([
                    "seconds": ["type": "integer", "minimum": 3, "maximum": 15],
                ], required: ["seconds"])),

            DeviceCapability(
                name: "bottle_daily_reset",
                description: "When on, the bottle clears its own usage statistics at 24:00 "
                           + "each day.",
                inputSchema: DeviceCapability.schema([
                    "on": ["type": "boolean"],
                ], required: ["on"])),

            DeviceCapability(
                name: "bottle_sync_clock",
                description: "Set the bottle's clock to the phone's current time. Its "
                           + "schedules depend on this.",
                inputSchema: DeviceCapability.schema()),

            DeviceCapability(
                name: "bottle_raw_command",
                description: "Write raw hex bytes to the bottle's control characteristic "
                           + "(A301). No framing or checksum is added. For protocol work "
                           + "only — an unknown opcode can put the bottle in an odd state, "
                           + "so `confirm` must be true.",
                inputSchema: DeviceCapability.schema([
                    "hex": ["type": "string",
                            "description": "Bytes as hex, e.g. '0E01'. See PROTOCOL.md."],
                    "confirm": ["type": "boolean"],
                ], required: ["hex"])),
        ]
    }

    // MARK: State

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "device_id": deviceID,
            "model": Self.model,
            "connected": isConnected,
            "connection_state": manager.state.text,
        ]
        if let v = manager.version {
            out["firmware_version"] = v.firmware
            out["hardware_version"] = v.hardware
        }
        guard let s = manager.status else { return out }
        out["water_temperature_c"] = s.temperatureC
        out["water_temperature_f"] = s.temperatureF
        out["battery_percent"] = s.batteryPercent
        out["charging"] = s.isCharging
        out["sterilising"] = s.isSterilising
        // The device reports a countdown, so completion is its complement.
        out["sterilise_percent_complete"] = max(0, min(100, 100 - s.steriliseProgress))
        out["sterilise_cycles_total"] = s.steriliseCount
        out["uv_intensity"] = s.uvIntensity == .strong ? "strong" : "normal"
        out["auto_sterilise_enabled"] = s.autoSteriliseEnabled
        out["touch_locked"] = s.touchLocked
        out["reminders_enabled"] = s.reminderEnabled
        out["screen_seconds"] = s.screenSeconds
        out["daily_auto_reset"] = s.dailyAutoReset
        out["raw_status_frame"] = s.rawHex
        return out
    }

    // MARK: Commands

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        // A command can arrive while the app is backgrounded and the link idle, so
        // bring it back up rather than failing.
        guard await manager.ensureConnected() else { throw DeviceError.notConnected }

        func bool(_ key: String) throws -> Bool {
            guard let v = args[key] as? Bool else {
                throw DeviceError.badArgument("'\(key)' must be a boolean")
            }
            return v
        }
        let confirmed = args["confirm"] as? Bool ?? false

        switch name {
        case "bottle_get_status":
            manager.send(.status)
            return try await settled()

        case "bottle_sterilise":
            let on = try bool("on")
            // Only starting needs confirmation; stopping is always safe.
            if on && !confirmed { throw DeviceError.confirmationRequired(name) }
            manager.send(.sterilise(on))

        case "bottle_set_uv_intensity":
            guard let level = args["level"] as? String,
                  let intensity = UVIntensity.named(level) else {
                throw DeviceError.badArgument("'level' must be 'normal' or 'strong'")
            }
            manager.send(.uvIntensity(intensity))

        case "bottle_auto_clean":
            manager.send(.autoSterilise(try bool("on")))

        case "bottle_touch_lock":
            manager.send(.touchLock(try bool("on")))

        case "bottle_reminders":
            manager.send(.reminderMaster(try bool("on")))

        case "bottle_set_screen_seconds":
            guard let raw = args["seconds"] as? Int, (3...15).contains(raw) else {
                throw DeviceError.badArgument("'seconds' must be an integer 3–15")
            }
            manager.send(.setScreenSeconds(UInt8(raw)))

        case "bottle_daily_reset":
            manager.send(.dailyAutoReset(try bool("on")))

        case "bottle_sync_clock":
            manager.send(.setClock(Date()))

        case "bottle_raw_command":
            guard confirmed else { throw DeviceError.confirmationRequired(name) }
            guard let hex = args["hex"] as? String,
                  let data = Data(hexString: hex), !data.isEmpty else {
                throw DeviceError.badArgument("'hex' must be an even-length hex string")
            }
            manager.send(.raw(data))

        default:
            throw DeviceError.unknownCommand(name)
        }

        return try await settled()
    }

    /// Every state-changing command is followed by a status read (see
    /// `BottleManager.send`), so waiting briefly returns the *result* of the command
    /// rather than the state before it.
    private func settled() async throws -> [String: Any] {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return snapshot()
    }
}

private extension UVIntensity {
    static func named(_ s: String) -> UVIntensity? {
        switch s.lowercased() {
        case "normal": return .normal
        case "strong": return .strong
        default:       return nil
        }
    }
}
