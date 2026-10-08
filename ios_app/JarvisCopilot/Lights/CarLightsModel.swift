import Foundation

/// A paired MELK controller.
struct CarLightsController: Codable, Equatable, Identifiable {
    /// The CoreBluetooth peripheral identifier.
    let id: String
    /// As advertised ("MELK-OC21…"): decides what it can do.
    var advertisedName: String
    /// What the user calls it.
    var name: String

    var capabilities: MelkCapabilities { MelkCapabilities(name: advertisedName) }
}

/// What a controller was last told. The controllers can't report their state, so this is what
/// the page, the preview and Jarvis show.
struct CarLightsState: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case color, white, temperature, effect, scene, deviceMic, phoneMusic
    }

    var on = true
    var mode: Mode = .color
    var color = MelkColor(r: 40, g: 110, b: 255)
    var brightness = 80
    /// The effects page's own brightness (the app has two sliders).
    var effectBrightness = 80
    /// 0 = fully warm, 100 = fully cold.
    var coldPercent = 50
    var whiteLevel = 100
    var effect: UInt8 = 0
    var speed = 50
    var scene: UInt8 = 1
    var micEffect: UInt8 = 3
    var micSensitivity = 50
    var pinOrder: MelkPinOrder = .rgb
    var pixelCount: Int?
    var timers: [MelkTimer] = [.defaults(.on), .defaults(.off)]

    /// The brightness of whatever is showing now.
    var shownBrightness: Int { [.effect, .scene, .deviceMic].contains(mode) ? effectBrightness : brightness }

    /// What the preview draws for it: the colour, or nil while an effect/music runs (it cycles).
    var displayColor: MelkColor? {
        guard on else { return nil }
        switch mode {
        case .color: return color
        case .white: return MelkColor(r: 255, g: 250, b: 240)
        case .temperature:
            let cold = Double(coldPercent) / 100
            return MelkColor(r: 255, g: UInt8(190 + 65 * cold), b: UInt8(120 + 135 * cold))
        case .effect, .scene, .deviceMic, .phoneMusic: return nil
        }
    }

    /// One line for a card or Jarvis: "Blue · 80 %", "7-Color Jump", "Off".
    var summary: String {
        guard on else { return "Off" }
        switch mode {
        case .color: return "\(MelkColor.presets.first { $0.color == color }?.name ?? color.hex) · \(brightness) %"
        case .white: return "White · \(whiteLevel) %"
        case .temperature: return "Colour temperature · \(coldPercent) % cold"
        case .effect: return MelkCatalog.effect(id: effect)?.name ?? "Effect \(effect)"
        case .scene: return MelkCatalog.scenes.first { $0.id == scene }?.name ?? "Scene \(scene)"
        case .deviceMic: return "Music (lights' mic) · \(MelkCatalog.micEffects[Int(micEffect) % 8])"
        case .phoneMusic: return "Music (phone mic)"
        }
    }
}

/// One thing to tell a controller.
enum CarLightsChange: Equatable {
    case power(Bool)
    case color(MelkColor)
    /// `page` nil: the page the current mode belongs to (Jarvis, the car's controls).
    case brightness(Int, page: Melk.LightMode? = nil)
    case white(Int)
    case temperature(coldPercent: Int)
    case effect(UInt8)
    case speed(Int)
    case scene(UInt8)
    case deviceMic(on: Bool)
    case micEffect(UInt8)
    case micSensitivity(Int)
    case pinOrder(MelkPinOrder)
    case pixelCount(Int)
    case timer(MelkTimer)

    /// Whether it changes what the lights show (and so ends phone-driven music).
    var changesWhatShows: Bool {
        switch self {
        case .power, .color, .white, .temperature, .effect, .scene, .deviceMic, .micEffect: return true
        case .brightness, .speed, .micSensitivity, .pinOrder, .pixelCount, .timer: return false
        }
    }

    /// What has to be resent if it was made while the lights were away.
    var pendingKey: String {
        switch self {
        case .pinOrder: return "pin"
        case .pixelCount: return "pixels"
        case .timer(let t): return "timer\(t.slot.rawValue)"
        default: return "state"
        }
    }

    /// The new state, and the frames that make it so (with how each is queued).
    func apply(to state: CarLightsState) -> (CarLightsState, [(Data, MelkWriteQueue.Kind)]) {
        var s = state
        var frames: [(Data, MelkWriteQueue.Kind)] = []
        switch self {
        case .power(let on):
            s.on = on
            frames = [(Melk.power(on), .replacesColor)]
        case .color(let c):
            s.color = c; s.mode = .color; s.on = true
            frames = [(Melk.color(c), .color)]
        case .brightness(let v, let page):
            let value = max(0, min(100, v))
            let current: Melk.LightMode = switch s.mode {
            case .color, .phoneMusic: .rgb
            case .white: .white
            case .temperature: .temperature
            case .effect, .scene, .deviceMic: .effects
            }
            let mode = page ?? current
            if mode == .effects { s.effectBrightness = value } else { s.brightness = value }
            frames = [(Melk.brightness(value, mode: mode), .other)]
        case .white(let v):
            s.whiteLevel = max(0, min(100, v)); s.mode = .white; s.on = true
            frames = [(Melk.whiteLevel(s.whiteLevel), .color)]
        case .temperature(let cold):
            s.coldPercent = max(0, min(100, cold)); s.mode = .temperature; s.on = true
            frames = [(Melk.colorTemperature(coldPercent: s.coldPercent), .color)]
        case .effect(let id):
            s.effect = min(id, 212); s.mode = .effect; s.on = true
            frames = [(Melk.effect(s.effect), .replacesColor)]
        case .speed(let v):
            s.speed = max(0, min(100, v))
            frames = [(Melk.speed(s.speed), .other)]
        case .scene(let id):
            s.scene = max(1, min(id, 28)); s.mode = .scene; s.on = true
            frames = [(Melk.scene(s.scene), .replacesColor)]
        case .deviceMic(let on):
            if on {
                s.mode = .deviceMic; s.on = true
                frames = [(Melk.deviceMic(true), .replacesColor), (Melk.deviceMicEffect(s.micEffect), .replacesColor)]
            } else {
                if s.mode == .deviceMic { s.mode = .color }
                frames = [(Melk.deviceMic(false), .replacesColor)]
            }
        case .micEffect(let m):
            s.micEffect = m & 0x07; s.mode = .deviceMic; s.on = true
            frames = [(Melk.deviceMic(true), .replacesColor), (Melk.deviceMicEffect(s.micEffect), .replacesColor)]
        case .micSensitivity(let v):
            s.micSensitivity = max(0, min(100, v))
            frames = [(Melk.deviceMicSensitivity(s.micSensitivity), .replacesColor)]
        case .pinOrder(let order):
            s.pinOrder = order
            frames = [(Melk.pinOrder(order), .replacesColor)]
        case .pixelCount(let n):
            s.pixelCount = max(Melk.pixelRange.lowerBound, min(Melk.pixelRange.upperBound, n))
            frames = [(Melk.pixelCount(s.pixelCount ?? n), .replacesColor)]
        case .timer(let t):
            if let i = s.timers.firstIndex(where: { $0.slot == t.slot }) { s.timers[i] = t } else { s.timers.append(t) }
            frames = [(Melk.timer(t), .other)]
        }
        return (s, frames)
    }
}
