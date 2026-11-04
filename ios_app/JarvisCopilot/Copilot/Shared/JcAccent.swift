import SwiftUI

/// THE accent colour. Change `hex` and everything follows: every screen, sheet
/// and popup, system alerts, the widget and Live Activities, the watch and the
/// Mac panel.
///
/// Nothing else spells the colour out. Every accent-coloured surface is `color`
/// or one of the role tokens below, all derived from `hex`, so a new accent
/// never means hunting literals. Compiled into the app, the widget, the watch
/// and the Mac dylib, so it is plain SwiftUI and nothing more.
///
/// 2026-11-04, his pick: black and white — "No more cyan accent in the whole
/// app … make this modular with a variable". The accent is white; the teal it
/// replaced was 0x3EC7C7. Anything drawn ON the accent (a main button's label,
/// a switch's knob) takes `onColor`, which flips to black for a light accent,
/// so any `hex` stays readable.
enum JcAccent {
    static let hex: UInt32 = 0xFFFFFF

    /// The accent itself: tints, icons, selection marks, outlines.
    static let color = shade(1)
    /// Text and icons drawn ON the accent: black on a light accent, white on a dark one.
    static let onColor: Color = isLight ? .black : .white

    // MARK: Roles — what screens use, so a change of look is one edit here

    /// The one main button on a screen (Save, Start, Allow, Send): filled.
    static let fill = color
    /// Its label.
    static let onFill = onColor
    /// A switch that's on: the track…
    static let control = color
    /// …and its knob.
    static let onControl = onColor

    // MARK: Shades

    /// Deeper, for data that needs a second step of the accent (charts, rings).
    static let deep = shade(0.75)
    /// Deeper still.
    static let deeper = shade(0.58)
    /// Lighter.
    static let bright = tint(0.2)
    /// A softer step of it: secondary chips, info marks. Mixed toward white — or,
    /// for a light accent that has nowhere lighter to go, a quieter grey step, so
    /// it stays distinct from the accent.
    static let soft = isLight ? shade(0.86) : tint(0.55)

    /// `hex` as CSS, for designs described in JSON (Dynamic Island demos).
    static var css: String { String(format: "#%06x", hex) }

    /// True when black reads better on the accent than white (relative luminance).
    static var isLight: Bool {
        let (r, g, b) = rgb
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6
    }

    /// The accent scaled toward black: 1 is the accent, 0 is black. Backdrop
    /// glows and dark grounds use the low end.
    static func shade(_ amount: Double, opacity: Double = 1) -> Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r * amount, green: g * amount, blue: b * amount, opacity: opacity)
    }

    /// The accent mixed toward white: 0 is the accent, 1 is white.
    static func tint(_ amount: Double, opacity: Double = 1) -> Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r + (1 - r) * amount, green: g + (1 - g) * amount,
                     blue: b + (1 - b) * amount, opacity: opacity)
    }

    private static var rgb: (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

/// The app's button surface (the Agents tab's Sleep / Unlock / Screen): a quiet
/// grey rounded rectangle with a white label; the main one is `JcAccent.fill`.
/// One place for the look of every button.
enum JcButton {
    /// The grey fill behind an ordinary button.
    static let fill = Color.white.opacity(0.09)
    /// A toggle-like button or tile that's on (a quick control, a chosen plan).
    static let selectedFill = Color.white.opacity(0.24)
    /// The label on either.
    static let label = Color(.sRGB, red: 0xED / 255, green: 0xF0 / 255, blue: 0xF8 / 255, opacity: 1)
    static let radius: CGFloat = 12
    static let compactRadius: CGFloat = 10
    /// Pressed: a step dimmer.
    static let pressedOpacity = 0.72
    static let disabledOpacity = 0.45
}

/// Health and fitness data colours — the Health tab's metric icons, rings and
/// charts. Separate from the UI accent on purpose (2026-11-04: the app went
/// black and white, "there can also be color for the icons in the health tab"):
/// change `activityHex` here, not `JcAccent.hex`, to recolour the data.
enum JcMetric {
    /// Activity, steps, exercise, Body Battery: the teal the app used to have.
    static let activityHex: UInt32 = 0x3EC7C7
    static let activity = rgb(activityHex)
    /// A light step of it (weight, info marks).
    static let activitySoft = mix(activityHex, toward: 1, 0.55)
    /// A deep step of it (deep sleep, relaxed).
    static let activityDeep = mix(activityHex, toward: 0, 0.25)
    /// Heart rate: the coral red the heart glyphs always had.
    static let heartHex: UInt32 = 0xFF5966
    static let heart = rgb(heartHex)
    /// Blood oxygen: the activity teal.
    static let oxygen = activity
    /// HRV and ECG: a light blue, apart from the teal beside it.
    static let rhythmHex: UInt32 = 0x7CB7FF
    static let rhythm = rgb(rhythmHex)

    private static func rgb(_ hex: UInt32) -> Color { mix(hex, toward: 0, 0) }

    /// `hex` moved `amount` of the way toward white (1) or black (0).
    private static func mix(_ hex: UInt32, toward end: Double, _ amount: Double) -> Color {
        let c = [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)].map { $0 / 255 }
        let m = c.map { $0 + (end - $0) * amount }
        return Color(.sRGB, red: m[0], green: m[1], blue: m[2], opacity: 1)
    }
}
