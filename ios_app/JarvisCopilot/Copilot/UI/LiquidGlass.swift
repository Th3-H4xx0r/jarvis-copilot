import SwiftUI

/// The app's one frosted-glass surface.
///
/// Lived at the bottom of `Shell/NavShell.swift`, which is the phone's tab bar
/// and nothing the Mac voice client builds — but the voice controls use this
/// modifier, so it is its own file now. Separate from `Glass.swift`, which is
/// the phone's design system (navigation bars, list rows) and stays on iOS.
extension View {
    /// Use the system optical material where it exists, with a readable material
    /// fallback on the older OS versions this app still supports.
    @ViewBuilder
    func jcLiquidGlass<S: Shape>(in shape: S, tint: Color = .clear) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint.opacity(0.2), in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}

/// The app's button: its label on clear liquid glass, with the colour in the label
/// (the accent, or a status colour) rather than a solid fill. For system-style text
/// buttons; custom buttons put `jcLiquidGlass` on their own shape the same way.
struct JcGlassButtonStyle: ButtonStyle {
    var tint: Color = JcTheme.accent
    var compact = false
    /// Stretch to the width offered, for a row of equal buttons.
    var full = false

    func makeBody(configuration: Configuration) -> some View {
        GlassLabel(configuration: configuration, style: self)
    }

    private struct GlassLabel: View {
        let configuration: Configuration
        let style: JcGlassButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: style.compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(maxWidth: style.full ? .infinity : nil)
                .padding(.horizontal, style.compact ? 12 : 18)
                .padding(.vertical, style.compact ? 6 : 12)
                .jcLiquidGlass(in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension ButtonStyle where Self == JcGlassButtonStyle {
    static var jcGlass: JcGlassButtonStyle { JcGlassButtonStyle() }
    static func jcGlass(tint: Color = JcTheme.accent, compact: Bool = false,
                        full: Bool = false) -> JcGlassButtonStyle {
        JcGlassButtonStyle(tint: tint, compact: compact, full: full)
    }
}
