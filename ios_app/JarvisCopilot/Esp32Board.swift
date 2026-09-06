import Foundation

/// The ESP32 dev board as Jarvis sees it: the onboard LED plus every exposed GPIO.
@MainActor
final class Esp32Board: WearableDevice {
    static let model = "Jarvis ESP32 DevKit V1"

    private unowned let manager: Esp32Manager
    init(manager: Esp32Manager) { self.manager = manager }

    var deviceID: String { manager.info?.deviceID ?? manager.connected?.id ?? "esp32" }
    var isConnected: Bool { manager.state == .ready }

    private var gpioSchema: [String: Any] {
        ["type": "integer", "description": "GPIO number. See esp32_get_state for the list and what each pin can do."]
    }

    var capabilities: [DeviceCapability] { [
        DeviceCapability(name: "esp32_get_state",
                         description: "Read every exposed GPIO: number, capabilities, current mode and level, plus Wi‑Fi and link status.",
                         inputSchema: DeviceCapability.schema()),
        DeviceCapability(name: "esp32_set_led",
                         description: "Turn the board's onboard blue LED on or off.",
                         inputSchema: DeviceCapability.schema(["on": ["type": "boolean"]], required: ["on"])),
        DeviceCapability(name: "esp32_blink_led",
                         description: "Blink the onboard LED a number of times.",
                         inputSchema: DeviceCapability.schema([
                            "count": ["type": "integer", "minimum": 1, "maximum": 255, "default": 3],
                            "period_ms": ["type": "integer", "minimum": 50, "maximum": 5000, "default": 300],
                         ])),
        DeviceCapability(name: "esp32_write_pin",
                         description: "Drive a GPIO high or low. Puts the pin in output mode if it isn't already.",
                         inputSchema: DeviceCapability.schema([
                            "gpio": gpioSchema,
                            "high": ["type": "boolean"],
                         ], required: ["gpio", "high"])),
        DeviceCapability(name: "esp32_read_pin",
                         description: "Read the current level of a GPIO.",
                         inputSchema: DeviceCapability.schema(["gpio": gpioSchema], required: ["gpio"])),
        DeviceCapability(name: "esp32_set_pin_mode",
                         description: "Configure a GPIO as output, input, input_pullup, input_pulldown or pwm. Input pins report edges to the app.",
                         inputSchema: DeviceCapability.schema([
                            "gpio": gpioSchema,
                            "mode": ["type": "string", "enum": Esp32Protocol.PinMode.allCases.filter { $0 != .unset }.map(\.wireName)],
                         ], required: ["gpio", "mode"])),
        DeviceCapability(name: "esp32_set_pwm",
                         description: "Output a PWM signal on a GPIO. Duty 0 is off, 255 is fully on.",
                         inputSchema: DeviceCapability.schema([
                            "gpio": gpioSchema,
                            "duty": ["type": "integer", "minimum": 0, "maximum": 255],
                         ], required: ["gpio", "duty"])),
        DeviceCapability(name: "esp32_pulse_pin",
                         description: "Drive a GPIO to a level for a number of milliseconds, then back. Good for momentary buttons and relays.",
                         inputSchema: DeviceCapability.schema([
                            "gpio": gpioSchema,
                            "high": ["type": "boolean", "default": true],
                            "duration_ms": ["type": "integer", "minimum": 1, "maximum": 10000, "default": 200],
                         ], required: ["gpio"])),
        DeviceCapability(name: "esp32_all_off",
                         description: "Set every output low and cancel any PWM, pulse or blink. Use this as the safe stop.",
                         inputSchema: DeviceCapability.schema()),
        DeviceCapability(name: "esp32_upload_script",
                         description: "Program the board: upload a Lua script that runs on it (sandboxed, survives reboots). Replaces the current script. See the jarvis-esp32 skill for the API (gpio, led, on_input, every, after, jarvis.notify, jarvis.invoke). Returns the compile result.",
                         inputSchema: DeviceCapability.schema([
                            "source": ["type": "string", "description": "Lua 5.4 source, up to 16 KB"],
                            "name": ["type": "string", "description": "Short name, e.g. door-sensor"],
                            "autostart": ["type": "boolean", "default": true, "description": "Run again after the board reboots"],
                         ], required: ["source", "name"])),
        DeviceCapability(name: "esp32_script_status",
                         description: "State of the script on the board (none/stopped/running/finished/error), its name and last error, plus recent console output.",
                         inputSchema: DeviceCapability.schema(["log_lines": ["type": "integer", "default": 20]])),
        DeviceCapability(name: "esp32_script_control",
                         description: "start, stop or delete the script stored on the board.",
                         inputSchema: DeviceCapability.schema([
                            "action": ["type": "string", "enum": ["start", "stop", "delete"]],
                         ], required: ["action"])),
    ] }

    func snapshot() -> [String: Any] {
        let pins: [[String: Any]] = manager.pins.map { pin in
            let st = manager.pinStates[pin.gpio]
            var caps: [String] = []
            if pin.capabilities.contains(.input) { caps.append("input") }
            if pin.capabilities.contains(.output) { caps.append("output") }
            if pin.capabilities.contains(.pwm) { caps.append("pwm") }
            if pin.capabilities.contains(.strapping) { caps.append("strapping") }
            if pin.capabilities.contains(.led) { caps.append("onboard_led") }
            return [
                "gpio": Int(pin.gpio),
                "capabilities": caps,
                "mode": (st?.mode ?? .unset).wireName,
                "value": Int(st?.value ?? 0),
            ]
        }
        var out: [String: Any] = [
            "connected": isConnected,
            "link": manager.activeLink?.rawValue ?? "none",
            "led_on": manager.ledOn,
            "led_blinking": manager.ledBlinking,
            "pins": pins,
        ]
        if let info = manager.info {
            out["firmware"] = info.firmwareString
            out["uptime_s"] = Int(info.uptimeSeconds)
        }
        if let s = manager.script {
            out["script"] = ["state": s.state.label.lowercased(), "name": s.name, "size": s.size,
                             "autostart": s.autostart, "error": s.error]
        }
        if let w = manager.wifi {
            out["wifi"] = [
                "state": w.state.label,
                "ssid": w.ssid,
                "ip": w.ip as Any,
                "hostname": w.hostname,
                "rssi": w.rssi,
            ]
        }
        return out
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        guard isConnected else { throw DeviceError.notConnected }
        switch name {
        case "esp32_get_state":
            try await manager.refreshState()
            return snapshot()
        case "esp32_set_led":
            guard let on = args["on"] as? Bool else { throw DeviceError.badArgument("on") }
            try await manager.setLED(on)
            return ["led_on": manager.ledOn]
        case "esp32_blink_led":
            try await manager.blinkLED(count: intArg(args, "count", default: 3), periodMs: intArg(args, "period_ms", default: 300))
            return ["ok": true]
        case "esp32_write_pin":
            let gpio = try gpioArg(args)
            guard let high = args["high"] as? Bool else { throw DeviceError.badArgument("high") }
            try await manager.writePin(gpio, high: high)
            return ["gpio": Int(gpio), "high": high]
        case "esp32_read_pin":
            let gpio = try gpioArg(args)
            let high = try await manager.readPin(gpio)
            return ["gpio": Int(gpio), "high": high]
        case "esp32_set_pin_mode":
            let gpio = try gpioArg(args)
            guard let raw = args["mode"] as? String, let mode = Esp32Protocol.PinMode.from(wireName: raw), mode != .unset else {
                throw DeviceError.badArgument("mode")
            }
            try await manager.setPinMode(gpio, mode)
            return ["gpio": Int(gpio), "mode": mode.wireName]
        case "esp32_set_pwm":
            let gpio = try gpioArg(args)
            let duty = intArg(args, "duty", default: -1)
            try await manager.setPWM(gpio, duty: duty)
            return ["gpio": Int(gpio), "duty": duty]
        case "esp32_pulse_pin":
            let gpio = try gpioArg(args)
            let high = args["high"] as? Bool ?? true
            try await manager.pulsePin(gpio, high: high, durationMs: intArg(args, "duration_ms", default: 200))
            return ["ok": true]
        case "esp32_all_off":
            try await manager.allOff()
            return ["ok": true]
        case "esp32_upload_script":
            guard let source = args["source"] as? String, !source.isEmpty else { throw DeviceError.badArgument("source") }
            let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "script"
            let autostart = args["autostart"] as? Bool ?? true
            do {
                try await manager.uploadScript(source, name: name, autostart: autostart)  // also remembers the summary
            } catch Esp32Error.scriptFailed(let message) {
                return ["ok": false, "compile_error": message]
            }
            let s = manager.script
            return ["ok": true, "state": s?.state.label.lowercased() ?? "running", "name": name, "bytes": source.utf8.count]
        case "esp32_script_status":
            try await manager.refreshScript()
            let n = max(1, min(intArg(args, "log_lines", default: 20), 100))
            var out: [String: Any] = ["log": Array(manager.scriptLog.suffix(n))]
            if let s = manager.script {
                out["state"] = s.state.label.lowercased(); out["name"] = s.name; out["size"] = s.size
                out["autostart"] = s.autostart; out["error"] = s.error
            }
            return out
        case "esp32_script_control":
            switch args["action"] as? String {
            case "start":  try await manager.startScript()
            case "stop":   try await manager.stopScript()
            case "delete": try await manager.deleteScript()
            default: throw DeviceError.badArgument("action")
            }
            return ["ok": true, "state": manager.script?.state.label.lowercased() ?? "unknown"]
        default:
            throw DeviceError.unknownCommand(name)
        }
    }

    private func intArg(_ args: [String: Any], _ key: String, default d: Int) -> Int {
        if let v = args[key] as? Int { return v }
        if let v = args[key] as? Double { return Int(v) }
        if let s = args[key] as? String, let v = Int(s) { return v }
        return d
    }

    private func gpioArg(_ args: [String: Any]) throws -> UInt8 {
        let n = intArg(args, "gpio", default: -1)
        guard (0...255).contains(n), manager.pins.contains(where: { $0.gpio == UInt8(n) }) else {
            throw DeviceError.badArgument("gpio \(n) is not exposed; call esp32_get_state for the list")
        }
        return UInt8(n)
    }
}
