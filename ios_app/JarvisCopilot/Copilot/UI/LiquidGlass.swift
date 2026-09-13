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
