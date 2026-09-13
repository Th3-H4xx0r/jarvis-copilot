import SwiftUI

/// JarvisCopilot's mobile theme — dark glass with a cyan accent. A one-for-one port of
/// the Flutter client's `theme.dart`, so a screen ported from Dart keeps its exact
/// colours.
///
/// Dark-only by design: the embedded webui tabs render dark, so a light/dark flip
/// would flicker. `RootView` pins `.preferredColorScheme(.dark)` for the whole app.
///
/// The legacy token NAMES (`accent`, `surface`, …) are kept and retargeted to the
/// current palette so screens that reference them pick up the look for free;
/// glass-specific tokens (`glassFill`, `glassBorder`) are additions.
enum JcTheme {

    // MARK: Canvas

    static let bg = Color(jcHex: 0x070710)

    // MARK: Glass surfaces
    //
    // Translucent — ONLY for elements layered over the gradient backdrop (cards,
    // nav bar, pills). Use `GlassCard` / `glassFill` explicitly.

    static let glassFill = Color(jcHex: 0xFFFFFF, alpha: 0x14 / 255.0)      // white @ ~8%
    static let glassBorder = Color(jcHex: 0xFFFFFF, alpha: 0x1A / 255.0)    // white @ ~10%

    // MARK: Solid surfaces
    //
    // For backgrounds that must be opaque (drawers, dialogs, bottom sheets, message
    // bubbles). Aliasing these to glass made sheets bleed the aurora through — the
    // recurring JARVIS-skin gotcha.

    static let surface = Color(jcHex: 0x14141F)
    static let surfaceAlt = Color(jcHex: 0x1C1C2A)
    static let border = glassBorder

    // MARK: Text

    static let text = Color(jcHex: 0xEDF0F8)
    static let muted = Color(jcHex: 0x8A93A8)

    // MARK: Brand
    //
    // The app's accent is cyan, everywhere — pages, sheets, popups, system
    // alerts (Assets `AccentColor` carries the same value for UIKit). It used to
    // be violet, with cyan only on the More tab; the whole app now matches that.

    static let accent = Color(jcHex: 0x46E0E0)          // cyan
    static let accentAlt = Color(jcHex: 0xFF6FD8)       // pink
    static let cyan = Color(jcHex: 0x46E0E0)
    /// The secondary accent — info chips, a running tool, your own message's
    /// wash. A soft cyan, so nothing in the app reads as a second brand colour.
    /// (Named for the light blue it replaced.)
    static let blue = Color(jcHex: 0x9BEFEA)

    /// Primary action colour — the filled CTAs (mic / send / Pair) and their
    /// ticks. Teal: the accent, deep enough that the white label on a filled
    /// button stays readable. (Named for the blue it replaced.)
    static let primaryBlue = Color(jcHex: 0x14A8AA)
    static let primaryBlueLo = Color(jcHex: 0x0C7F82)
    static let primaryBlueHi = Color(jcHex: 0x5EE6E4)

    static let success = Color(jcHex: 0x5BE5A0)
    static let amber = Color(jcHex: 0xFFC34D)           // warning / mock-mode
    /// Muted slate blue for the user's own bubbles and the active send button.
    static let slate = Color(jcHex: 0x546689)
    static let danger = Color(jcHex: 0xFF6B7E)

    // MARK: Gradients

    /// Brand gradient: bright cyan into deep teal.
    static let brandGradient = LinearGradient(
        colors: [cyan, primaryBlue],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Primary CTA gradient — the glossy teal behind the mic / send / Pair buttons.
    /// Use `primaryBlue` where a single colour is needed.
    static let blueGradient = LinearGradient(
        colors: [primaryBlueHi, primaryBlue, primaryBlueLo],
        startPoint: UnitPoint(x: 0.35, y: 0.2), endPoint: .bottomTrailing)

    // MARK: Metrics
    //
    // The radii the Flutter widgets use, so ported screens line up.

    static let cardRadius: CGFloat = 22
    static let fieldRadius: CGFloat = 14
}

/// The app's type scale, mirroring `theme.dart`'s `_textTheme`.
///
/// Flutter bundles Inter; there is no bundled font here, so these are the system
/// face at the same sizes and weights. Sizes are fixed (as in Flutter) rather than
/// Dynamic-Type-relative, otherwise the ported layouts break at large sizes.
enum JcText {
    /// 20 / semibold — section and screen titles (`titleLarge`).
    static let title = Font.system(size: 20, weight: .semibold, design: .default)
    /// 15 / regular — the default reading size (`bodyLarge`).
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    /// 14 / semibold — buttons and controls (`labelLarge`).
    static let label = Font.system(size: 14, weight: .semibold, design: .default)
    /// 12 / medium — captions, muted metadata (`bodySmall`).
    static let small = Font.system(size: 12, weight: .medium, design: .default)
}

extension Color {
    /// `Color(jcHex: 0x46E0E0)`. Deliberately not called `hex:` so it can't collide
    /// with a same-named helper another area adds.
    init(jcHex value: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: alpha)
    }
}
