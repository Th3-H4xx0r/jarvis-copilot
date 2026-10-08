import Foundation

/// The MELK ("Magic Lantern") LED controllers' wire format. Every command is 9 bytes written to
/// characteristic FFF3 of service FFF0: `7E b1 CMD p1 p2 p3 p4 p5 EF` — no checksum, no sequence
/// number, no lamp address. Byte-exact from `magiclantern-re/PROTOCOL.md` (Magic Lantern v6.11.10,
/// decompiled); byte 1 looks like a length but isn't — copy every byte as written.
enum Melk {
    static let service = "FFF0"
    static let characteristic = "FFF3"
    /// Magic Lantern lists only names with this prefix.
    static let namePrefix = "MELK-"

    static func isController(name: String) -> Bool { name.hasPrefix(namePrefix) }

    private static func frame(_ bytes: [UInt8]) -> Data { Data(bytes) }
    private static func percent(_ v: Int) -> UInt8 { UInt8(max(0, min(100, v))) }

    // 5.1 Power
    static func power(_ on: Bool) -> Data {
        frame([0x7E, 0x04, 0x04, on ? 1 : 0, 0x00, on ? 1 : 0, 0xFF, 0x00, 0xEF])
    }

    // 5.3 / 5.10 Colour (trailer 0x10) and phone-driven music colour (trailer 0x20)
    static func color(_ c: MelkColor) -> Data { frame([0x7E, 0x07, 0x05, 0x03, c.r, c.g, c.b, 0x10, 0xEF]) }
    static func musicColor(_ c: MelkColor) -> Data { frame([0x7E, 0x07, 0x05, 0x03, c.r, c.g, c.b, 0x20, 0xEF]) }

    /// 5.4 Which page a brightness belongs to.
    enum LightMode: UInt8 { case rgb = 0x01, white = 0x02, temperature = 0x03, effects = 0xFF }

    // 5.4 Brightness 0–100 %
    static func brightness(_ value: Int, mode: LightMode) -> Data {
        frame([0x7E, 0x04, 0x01, percent(value), mode.rawValue, 0xFF, 0xFF, 0x00, 0xEF])
    }

    // 5.5 Colour temperature: 0 = fully warm, 100 = fully cold
    static func colorTemperature(coldPercent: Int) -> Data {
        let cold = percent(coldPercent)
        return frame([0x7E, 0x06, 0x05, 0x02, 100 - cold, cold, 0xFF, 0x08, 0xEF])
    }

    // 5.6 White channel 0–100 %
    static func whiteLevel(_ value: Int) -> Data { frame([0x7E, 0x05, 0x05, 0x01, percent(value), 0xFF, 0xFF, 0x08, 0xEF]) }

    // 5.7 Built-in effect 0–212, 5.8 speed 0–100, 5.9 scene 1–28 (MELK-OC / MELK-OT)
    static func effect(_ id: UInt8) -> Data { frame([0x7E, 0x05, 0x03, min(id, 212), 0x06, 0xFF, 0xFF, 0x00, 0xEF]) }
    static func speed(_ value: Int) -> Data { frame([0x7E, 0x04, 0x02, percent(value), 0xFF, 0xFF, 0xFF, 0x00, 0xEF]) }
    static func scene(_ id: UInt8) -> Data { frame([0x7E, 0x05, 0x31, max(1, min(id, 28)), 0x07, 0xFF, 0xFF, 0x01, 0xEF]) }

    // 5.11 The controller's own microphone
    static func deviceMic(_ on: Bool) -> Data { frame([0x7E, 0x04, 0x07, on ? 1 : 0, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]) }
    static func deviceMicEffect(_ index: UInt8) -> Data {
        frame([0x7E, 0x07, 0x03, 0x80 | (index & 0x07), 0x04, 0xFF, 0xFF, 0x00, 0xEF])
    }
    static func deviceMicSensitivity(_ value: Int) -> Data { frame([0x7E, 0x04, 0x06, percent(value), 0xFF, 0xFF, 0xFF, 0x00, 0xEF]) }

    // 5.12 Wire order, 5.13 LED count 10–1000 (little-endian)
    static func pinOrder(_ order: MelkPinOrder) -> Data {
        let b = order.bytes
        return frame([0x7E, 0x06, 0x81, b.0, b.1, b.2, 0xFF, 0x00, 0xEF])
    }
    static let pixelRange = 10...1000
    static func pixelCount(_ count: Int) -> Data {
        let n = UInt16(max(pixelRange.lowerBound, min(pixelRange.upperBound, count)))
        return frame([0x7E, 0x07, 0x21, UInt8(n & 0xFF), UInt8(n >> 8), 0x00, 0xFF, 0x00, 0xEF])
    }

    // 5.14 Time sync: weekday 0 = Sunday … 6 = Saturday
    static func timeSync(_ date: Date = Date(), calendar: Calendar = .current) -> Data {
        let c = calendar.dateComponents([.hour, .minute, .second, .weekday], from: date)
        return frame([0x7E, 0x07, 0x83, UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
                      UInt8(max(0, (c.weekday ?? 1) - 1)), 0xFF, 0xEF])
    }

    // 5.15 Timers: weekday mask bit0 = Monday … bit6 = Sunday, bit7 = enabled
    static func timer(_ t: MelkTimer) -> Data {
        frame([0x7E, 0x08, 0x82, UInt8(max(0, min(23, t.hour))), UInt8(max(0, min(59, t.minute))), 0x00,
               t.slot.rawValue, (t.days & 0x7F) | (t.enabled ? 0x80 : 0), 0xEF])
    }
    static func timerQuery(_ slot: MelkTimer.Slot) -> Data {
        frame([0x7E, 0x08, 0x82, 0xFF, 0xFF, 0xFF, slot.rawValue, 0x00, 0xEF])
    }

    /// A FFF3 read made after `timerQuery`; nil for anything else.
    static func parseTimer(_ data: Data) -> MelkTimer? {
        let b = [UInt8](data)
        guard b.count >= 9, b[0] == 0x7E, b[1] == 0x08, b[2] == 0x82, b[8] == 0xEF,
              let slot = MelkTimer.Slot(rawValue: b[6]) else { return nil }
        // A never-set timer answers FF FF: the app takes any value, so clamp rather than refuse.
        return MelkTimer(slot: slot, hour: min(Int(b[3]), 23), minute: min(Int(b[4]), 59),
                         days: b[7] & 0x7F, enabled: b[7] & 0x80 != 0)
    }
}

/// What a controller can do — Magic Lantern decides from the advertised name alone.
struct MelkCapabilities: Equatable {
    var hasTemperature: Bool
    var hasWhite: Bool
    var hasScenes: Bool
    var hasDeviceMic: Bool
    var hasTimers: Bool

    init(name: String) {
        let upper = name.uppercased()
        let model = upper.hasPrefix(Melk.namePrefix) ? String(upper.dropFirst(Melk.namePrefix.count)) : upper
        // `^MELK-.+CT.*` and `^MELK-.+W.*`: a match after the first character of the model.
        hasTemperature = model.dropFirst().contains("CT")
        hasWhite = model.dropFirst().contains("W")
        hasScenes = model.hasPrefix("OC") || model.hasPrefix("OT")
        hasDeviceMic = !(model.hasPrefix("OE") || model.hasPrefix("OB") || model.hasPrefix("TX"))
        hasTimers = !model.hasPrefix("TX")
    }
}

/// The controller's colour channels in the order its LED strip is wired.
enum MelkPinOrder: String, CaseIterable, Codable, Identifiable {
    case rgb = "RGB", rbg = "RBG", grb = "GRB", gbr = "GBR", brg = "BRG", bgr = "BGR"
    var id: String { rawValue }

    /// 1 = R, 2 = G, 3 = B, in wire order.
    var bytes: (UInt8, UInt8, UInt8) {
        let digits = rawValue.map { ch -> UInt8 in ch == "R" ? 1 : ch == "G" ? 2 : 3 }
        return (digits[0], digits[1], digits[2])
    }
}

/// One of the controller's two weekly timers.
struct MelkTimer: Codable, Equatable, Identifiable {
    /// 0 turns the lights on at the time, 1 turns them off.
    enum Slot: UInt8, Codable { case on = 0, off = 1 }
    var slot: Slot
    var hour: Int
    var minute: Int
    /// bit0 Monday … bit6 Sunday.
    var days: UInt8
    var enabled: Bool

    var id: UInt8 { slot.rawValue }

    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func defaults(_ slot: Slot) -> MelkTimer {
        MelkTimer(slot: slot, hour: slot == .on ? 18 : 23, minute: 0, days: 0x7F, enabled: false)
    }
}

/// An 8-bit RGB colour.
struct MelkColor: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB" / "RRGGBB", or a preset's name.
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let preset = Self.presets.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            self = preset.color
            return
        }
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(r: UInt8(value >> 16 & 0xFF), g: UInt8(value >> 8 & 0xFF), b: UInt8(value & 0xFF))
    }

    /// The quick swatches (and the colour names Jarvis understands).
    static let presets: [(name: String, color: MelkColor)] = [
        ("Red", MelkColor(r: 255, g: 0, b: 0)), ("Orange", MelkColor(r: 255, g: 90, b: 0)),
        ("Amber", MelkColor(r: 255, g: 160, b: 20)), ("Yellow", MelkColor(r: 255, g: 230, b: 0)),
        ("Green", MelkColor(r: 0, g: 255, b: 40)), ("Cyan", MelkColor(r: 0, g: 230, b: 255)),
        ("Blue", MelkColor(r: 0, g: 60, b: 255)), ("Purple", MelkColor(r: 140, g: 0, b: 255)),
        ("Pink", MelkColor(r: 255, g: 40, b: 160)), ("White", MelkColor(r: 255, g: 255, b: 255)),
    ]

    /// Phone-driven music cycles these, the app's rotation.
    static let musicRotation: [MelkColor] = [
        MelkColor(r: 255, g: 0, b: 0), MelkColor(r: 0, g: 255, b: 0), MelkColor(r: 0, g: 0, b: 255),
        MelkColor(r: 255, g: 255, b: 0), MelkColor(r: 255, g: 0, b: 255), MelkColor(r: 0, g: 255, b: 255),
        MelkColor(r: 255, g: 255, b: 255),
    ]
    static let black = MelkColor(r: 0, g: 0, b: 0)
}
