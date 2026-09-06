import SwiftUI

/// The brand mark on the pair screen: the app icon artwork itself (the orbit-ring
/// sphere), rounded like a Home Screen icon and softly lit. Using the icon rather
/// than a second symbol keeps the mark people see in-app identical to the one on
/// their Home Screen.
struct JcLogo: View {
    var size: CGFloat = 56

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: JcTheme.primaryBlue.opacity(0.45), radius: size * 0.18, y: size * 0.08)
            .accessibilityLabel("JarvisCopilot")
    }
}
