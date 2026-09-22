import SwiftUI

/// The three STATE colours, in the one place both the app and the widget can
/// read them.
///
/// `JcTheme` is the app's palette and is not compiled into the widget
/// extension, which is why the widget grew colour literals (the heart red in
/// `RingWorkoutActivity`). A Live Activity that reports recording has to use
/// the SAME red as the recording light on the Live screen — a different red
/// would read as a different state — so the hexes live here, in `Shared`, and
/// `JcTheme` re-exports them under the names screens already use.
///
/// These are deliberately NOT derived from `JcAccent`: the accent means "you
/// can tap this" everywhere in this app, and spending it on a state would make
/// the one red thing on screen ambiguous (see `LiveCaptureDot`).
enum JcState {
    /// Recording, destructive, failed. `#FF6B7E`.
    static let dangerHex: UInt32 = 0xFF6B7E
    /// Warning, paused, mock mode. `#FFC34D`.
    static let amberHex: UInt32 = 0xFFC34D
    /// Succeeded, healthy. `#5BE5A0`.
    static let successHex: UInt32 = 0x5BE5A0

    static let danger = color(dangerHex)
    static let amber = color(amberHex)
    static let success = color(successHex)

    /// Built here rather than through `Color(jcHex:)`: that helper is declared
    /// beside `JcTheme` and so is app-only, and this type has to compile in the
    /// widget too.
    private static func color(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: 1)
    }
}
