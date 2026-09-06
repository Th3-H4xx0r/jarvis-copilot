import SwiftUI

/// Rounded gradient disc with "JC" centred — the brand mark on the pair page,
/// settings page and launcher tiles. Ported from `widgets/jc_logo.dart`.
struct JcLogo: View {
    var size: CGFloat = 56

    var body: some View {
        Text("JC")
            .font(.system(size: size * 0.4, weight: .heavy))
            .kerning(0.5)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(JcTheme.brandGradient,
                        in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .shadow(color: JcTheme.accent.opacity(0.4), radius: 9, y: 6)
    }
}
