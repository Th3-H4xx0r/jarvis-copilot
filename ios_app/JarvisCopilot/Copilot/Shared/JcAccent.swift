import SwiftUI

/// THE accent colour. Change `hex` and everything follows: every screen, sheet
/// and popup, system alerts, the widget and Live Activities, the watch and the
/// Mac panel.
///
/// Nothing else spells the colour out. Every accent-coloured surface is `color`
/// or one of the shades below, all derived from `hex`, so a new accent never
/// means hunting literals. Compiled into the app, the widget, the watch and the
/// Mac dylib, so it is plain SwiftUI and nothing more.
enum JcAccent {
    static let hex: UInt32 = 0x3EC7C7

    /// The accent itself: tints, toggles, icons, selection marks, outlines.
    static let color = shade(1)
    /// Deeper, for solid fills under a white label (send, CTAs, swipe actions).
    static let deep = shade(0.75)
    /// Deeper still: the shadowed end of the CTA gradient.
    static let deeper = shade(0.58)
    /// Lighter: the gloss on the CTA gradient.
    static let bright = tint(0.2)
    /// A soft wash of it: secondary chips, your own message's bubble.
    static let soft = tint(0.55)

    /// `hex` as CSS, for designs described in JSON (Dynamic Island demos).
    static var css: String { String(format: "#%06x", hex) }

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
