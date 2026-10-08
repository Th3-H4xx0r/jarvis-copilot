import Combine
import SwiftUI

/// The car's lights as a Jarvis device and as something linked to the car. Its `lights_*` skills
/// reach everything Magic Lantern can do; its controls (power, brightness, colour, effect) join
/// the car's page, CarPlay and `car_set_control`.
///
/// A target is all the lights, one controller, or a lamp — a lamp means its controller: every
/// lamp on one controller shows the same thing (the protocol has no lamp address).
@MainActor
final class CarLightsDevice: WearableDevice, LinkableWearable {
    static let shared = CarLightsDevice()
    static let kind = "lights"
    static let model = "Car lights (Magic Lantern)"
    private static let idKey = "jc.lights.deviceID"

    let manager: CarLightsManager
    let layout: CarLightLayout
    let deviceID: String
    private var registered = false

    init(manager: CarLightsManager = .shared, layout: CarLightLayout = .bundled, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.layout = layout
        if let id = defaults.string(forKey: Self.idKey) {
            deviceID = id
        } else {
            deviceID = "lights-" + UUID().uuidString.prefix(8).lowercased()
            defaults.set(deviceID, forKey: Self.idKey)
        }
    }

    var isConnected: Bool { manager.anyReady }
    var linkKind: String? { Self.kind }

    /// Joins Jarvis once a controller is paired; leaves when the last one is forgotten.
    func refreshMembership() {
        if manager.controllers.isEmpty {
            if registered { DeviceRegistry.shared.remove(deviceID: deviceID); BridgeClient.shared.sendRegistration() }
            registered = false
        } else {
            DeviceRegistry.shared.syncMembership(of: self, identity: Self.kind, model: Self.model)
            registered = DeviceRegistry.shared.device(id: deviceID) != nil
        }
    }

    // MARK: Linked to the car

    var kind: String { Self.kind }
    var title: String { "Car lights" }
    var symbol: String { "light.strip.2" }

    var linkStatus: LinkedWearableStatus {
        guard let first = manager.controllers.first else { return LinkedWearableStatus(text: "Not paired", connected: false) }
        let ready = manager.controllers.filter { manager.link(for: $0.id) == .ready }.count
        let summary = manager.state(for: first.id).summary
        if ready == 0 { return LinkedWearableStatus(text: "Away · \(summary)", connected: false) }
        return LinkedWearableStatus(text: summary, connected: true)
    }

    var changes: AnyPublisher<Void, Never> { manager.objectWillChange.map { _ in () }.eraseToAnyPublisher() }

    func card(namespace: Namespace.ID) -> AnyView { AnyView(CarLightsEntryCard(namespace: namespace)) }

    /// No screen of its own in CarPlay: its controls are on the car's tab.
    var carPlayScreen: CarPlayScreen? { nil }

    /// Power, brightness, colour and effect — for every light at once.
    var controls: [WearableControl] {
        guard let first = manager.controllers.first else { return [] }
        let s = manager.state(for: first.id)
        let manager = self.manager
        let colorOptions = MelkColor.presets.map { WearableControl.Option(id: $0.name.lowercased(), title: $0.name) }
        let currentColor = MelkColor.presets.first { $0.color == s.color }?.name.lowercased() ?? ""
        let effects = Self.carEffects.compactMap(MelkCatalog.effect(id:))
        return [
            WearableControl(id: "lights.power", title: "Lights", symbol: "power", kind: .toggle(isOn: s.on)) { value in
                if case .toggle(let on) = value { manager.apply(.power(on)) }
            },
            WearableControl(id: "lights.brightness", title: "Brightness", symbol: "sun.max",
                            kind: .level(value: Double(s.shownBrightness), range: 0...100, step: 5, unit: "%")) { value in
                if case .level(let v) = value { manager.apply(.brightness(Int(v))) }
            },
            WearableControl(id: "lights.color", title: "Colour", symbol: "paintpalette",
                            kind: .choice(selected: s.mode == .color ? currentColor : "", options: colorOptions)) { value in
                if case .choice(let id) = value, let preset = MelkColor.presets.first(where: { $0.name.lowercased() == id }) {
                    manager.apply(.color(preset.color))
                }
            },
            WearableControl(id: "lights.effect", title: "Effect", symbol: "sparkles",
                            kind: .choice(selected: s.mode == .effect ? String(s.effect) : "",
                                          options: effects.map { .init(id: String($0.id), title: $0.name) })) { value in
                if case .choice(let id) = value, let effect = UInt8(id) { manager.apply(.effect(effect)) }
            },
        ]
    }

    /// The effects offered from the car (CarPlay lists stay short); the lights' page has all 213.
    static let carEffects: [UInt8] = [0, 199, 193, 196, 212, 77, 83, 181, 39, 103]

    // MARK: Targets

    /// "all" / nil, a controller's name or id, or a lamp's name or id → controller ids.
    func targets(_ raw: Any?) throws -> [String]? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              text.lowercased() != "all" else { return nil }
        if let c = manager.controllers.first(where: { $0.id == text || $0.name.caseInsensitiveCompare(text) == .orderedSame }) {
            return [c.id]
        }
        if let lamp = layout.lamps.first(where: { $0.id == text || $0.name.caseInsensitiveCompare(text) == .orderedSame }),
           let id = CarLightLayout.controllerID(for: lamp, in: manager.controllers) {
            return [id]
        }
        throw DeviceError.badArgument("no light or lamp called '\(text)' — lamps: \(layout.lamps.map(\.name).joined(separator: ", "))")
    }

    // MARK: Skills

    var capabilities: [DeviceCapability] {
        let target: [String: Any] = ["type": "string",
            "description": "Which lights: omit or 'all', a controller's name, or a lamp (\(layout.lamps.map(\.name).joined(separator: ", "))). Lamps on one controller always match."]
        return [
            DeviceCapability(name: "lights_get_status", description: """
                The car's LED lights (Magic Lantern controllers): each controller with its link, what it can do and \
                what it was last set to (power, mode, colour, brightness, effect, speed, music, timers, wiring), and \
                every lamp with the controller that drives it.
                """, inputSchema: DeviceCapability.schema()),
            DeviceCapability(name: "lights_set", description: """
                Change the car's lights. Give any of: power, color (#RRGGBB or red/orange/amber/yellow/green/cyan/\
                blue/purple/pink/white), brightness 0–100, white 0–100 (W units), temperature 0–100 % cold (CT units), \
                effect (id or name from lights_list_effects), speed 0–100, scene (OC/OT units), music \
                ('lights_mic' / 'phone_mic' / 'off') with mic_effect 0–7 and sensitivity 0–100.
                """, inputSchema: DeviceCapability.schema([
                    "target": target,
                    "power": ["type": "boolean"],
                    "color": ["type": "string"],
                    "brightness": ["type": "integer", "minimum": 0, "maximum": 100],
                    "white": ["type": "integer", "minimum": 0, "maximum": 100],
                    "temperature": ["type": "integer", "minimum": 0, "maximum": 100],
                    "effect": ["type": "string"],
                    "speed": ["type": "integer", "minimum": 0, "maximum": 100],
                    "scene": ["type": "string"],
                    "music": ["type": "string", "enum": ["lights_mic", "phone_mic", "off"]],
                    "mic_effect": ["type": "integer", "minimum": 0, "maximum": 7],
                    "sensitivity": ["type": "integer", "minimum": 0, "maximum": 100],
                ])),
            DeviceCapability(name: "lights_list_effects", description: """
                The lights' 213 built-in effects by group (Basic, Curtain, Trans, Water, Flow, Tail, Run, RunBack) \
                with ids, the 28 scenes, and the 8 microphone effects.
                """, inputSchema: DeviceCapability.schema()),
            DeviceCapability(name: "lights_timer", description: """
                The lights' two weekly timers: 'on' turns them on at a time, 'off' turns them off. Without time/days/\
                enabled it reads them back from the lights; otherwise it sets one.
                """, inputSchema: DeviceCapability.schema([
                    "target": target,
                    "timer": ["type": "string", "enum": ["on", "off"]],
                    "time": ["type": "string", "description": "24 h HH:MM"],
                    "days": ["type": "array", "items": ["type": "string", "enum": MelkTimer.weekdays]],
                    "enabled": ["type": "boolean"],
                ])),
            DeviceCapability(name: "lights_setup", description: """
                Wiring settings, normally set once: pin_order (RGB, RBG, GRB, GBR, BRG, BGR — when colours come out \
                wrong) and led_count (10–1000 LEDs on the strip).
                """, inputSchema: DeviceCapability.schema([
                    "target": target,
                    "pin_order": ["type": "string", "enum": MelkPinOrder.allCases.map(\.rawValue)],
                    "led_count": ["type": "integer", "minimum": 10, "maximum": 1000],
                ])),
        ]
    }

    func snapshot() -> [String: Any] {
        [
            "controllers": manager.controllers.map { c -> [String: Any] in
                let s = manager.state(for: c.id)
                let caps = c.capabilities
                return [
                    "name": c.name, "model": c.advertisedName, "connected": manager.link(for: c.id) == .ready,
                    "summary": s.summary, "on": s.on, "mode": s.mode.rawValue, "color": s.color.hex,
                    "brightness": s.brightness, "effect_brightness": s.effectBrightness,
                    "effect": MelkCatalog.effect(id: s.effect)?.name ?? "", "speed": s.speed,
                    "white": s.whiteLevel, "temperature_cold_percent": s.coldPercent,
                    "pin_order": s.pinOrder.rawValue, "led_count": s.pixelCount.map { $0 as Any } ?? NSNull(),
                    "can": ["white": caps.hasWhite, "temperature": caps.hasTemperature, "scenes": caps.hasScenes,
                            "lights_mic": caps.hasDeviceMic, "timers": caps.hasTimers],
                    "lamps": layout.lamps(on: c.id, controllers: manager.controllers).map(\.name),
                ]
            },
            "lamps": layout.lamps.map { ["id": $0.id, "name": $0.name] },
            "note": "Lamps on one controller always show the same colour and effect.",
        ]
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        guard !manager.controllers.isEmpty || name == "lights_list_effects" else {
            throw DeviceError.badArgument("no car lights are paired yet — pair them on the iPhone (Car → Car lights)")
        }
        switch name {
        case "lights_get_status":
            return snapshot()
        case "lights_list_effects":
            return [
                "effects": MelkCatalog.effectTabs.map { tab in
                    ["group": tab.title, "effects": tab.items.map { ["id": Int($0.id), "name": $0.name] }]
                },
                "scenes": MelkCatalog.scenes.map { ["id": Int($0.id), "name": $0.name] },
                "mic_effects": MelkCatalog.micEffects.enumerated().map { ["id": $0.offset, "name": $0.element] },
            ]
        case "lights_set":
            let ids = try targets(args["target"])
            let changes = try Self.changes(from: args)
            guard !changes.isEmpty || args["music"] != nil else { throw DeviceError.badArgument("nothing to change") }
            for change in changes { manager.apply(change, to: ids) }
            switch args["music"] as? String {
            case "phone_mic": CarLightsMusic.shared.startPhoneMic(for: ids)
            case "off", "lights_mic": CarLightsMusic.shared.stopPhoneMic()
            default: break
            }
            return ["ok": true, "now": snapshot()["controllers"] ?? []]
        case "lights_timer":
            let ids = try targets(args["target"]) ?? manager.controllers.map(\.id)
            guard let slotName = args["timer"] as? String else {
                var out: [[String: Any]] = []
                for id in ids {
                    let timers = await manager.readTimers(id) ?? manager.state(for: id).timers
                    out.append(["controller": manager.controllers.first { $0.id == id }?.name ?? id,
                                "timers": timers.map(Self.timerJSON)])
                }
                return ["timers": out]
            }
            let slot: MelkTimer.Slot = slotName == "off" ? .off : .on
            for id in ids {
                var t = manager.state(for: id).timers.first { $0.slot == slot } ?? .defaults(slot)
                if let time = args["time"] as? String {
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                        throw DeviceError.badArgument("time is HH:MM, 24 h")
                    }
                    t.hour = parts[0]; t.minute = parts[1]
                }
                if let days = args["days"] as? [String] {
                    t.days = days.reduce(0) { mask, day in
                        guard let i = MelkTimer.weekdays.firstIndex(where: { $0.caseInsensitiveCompare(String(day.prefix(3))) == .orderedSame }) else { return mask }
                        return mask | UInt8(1 << i)
                    }
                }
                t.enabled = args["enabled"] as? Bool ?? true
                manager.apply(.timer(t), to: [id])
            }
            return ["ok": true]
        case "lights_setup":
            let ids = try targets(args["target"])
            if let raw = args["pin_order"] as? String {
                guard let order = MelkPinOrder(rawValue: raw.uppercased()) else { throw DeviceError.badArgument("pin_order is one of RGB, RBG, GRB, GBR, BRG, BGR") }
                manager.apply(.pinOrder(order), to: ids)
            }
            if let count = (args["led_count"] as? NSNumber)?.intValue {
                guard Melk.pixelRange.contains(count) else { throw DeviceError.badArgument("led_count is 10–1000") }
                manager.apply(.pixelCount(count), to: ids)
            }
            return ["ok": true]
        default:
            throw DeviceError.unknownCommand(name)
        }
    }

    /// `lights_set` arguments → changes, power first.
    static func changes(from args: [String: Any]) throws -> [CarLightsChange] {
        var out: [CarLightsChange] = []
        func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
        if let on = args["power"] as? Bool { out.append(.power(on)) }
        if let text = args["color"] as? String {
            guard let c = MelkColor(text: text) else { throw DeviceError.badArgument("color is #RRGGBB or a colour name") }
            out.append(.color(c))
        }
        if let v = int("white") { out.append(.white(v)) }
        if let v = int("temperature") { out.append(.temperature(coldPercent: v)) }
        func text(_ key: String) -> String? { args[key] as? String ?? (args[key] as? NSNumber)?.stringValue }
        if let text = text("effect") {
            guard let e = MelkCatalog.effect(named: text) else { throw DeviceError.badArgument("no effect '\(text)' — see lights_list_effects") }
            out.append(.effect(e.id))
        }
        if let text = text("scene") {
            guard let s = MelkCatalog.scene(named: text) else { throw DeviceError.badArgument("no scene '\(text)'") }
            out.append(.scene(s.id))
        }
        if let v = int("speed") { out.append(.speed(v)) }
        if let v = int("brightness") { out.append(.brightness(v)) }
        switch args["music"] as? String {
        case "lights_mic":
            out.append(int("mic_effect").map { .micEffect(UInt8(max(0, min(7, $0)))) } ?? .deviceMic(on: true))
        case "off":
            out.append(.deviceMic(on: false))
        default:
            if let m = int("mic_effect") { out.append(.micEffect(UInt8(max(0, min(7, m))))) }
        }
        if let v = int("sensitivity") { out.append(.micSensitivity(v)) }
        return out
    }

    static func timerJSON(_ t: MelkTimer) -> [String: Any] {
        ["timer": t.slot == .on ? "on" : "off", "time": String(format: "%02d:%02d", t.hour, t.minute),
         "days": MelkTimer.weekdays.enumerated().filter { t.days & UInt8(1 << $0.offset) != 0 }.map(\.element),
         "enabled": t.enabled]
    }
}
