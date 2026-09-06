import SwiftUI

/// Primary CTA — the iridescent brand gradient with a white foreground.
/// Ported from `widgets/gradient_button.dart`.
struct GradientButton: View {
    let title: String
    var symbol: String? = nil
    var busy: Bool = false
    var full: Bool = false
    /// `nil` renders the button disabled, matching Flutter's nullable `onPressed`.
    var action: (() -> Void)?

    init(_ title: String,
         symbol: String? = nil,
         busy: Bool = false,
         full: Bool = false,
         action: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.busy = busy
        self.full = full
        self.action = action
    }

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            // The Voice page's primary control: one flat brand-blue capsule, no
            // gradient, no glow. (The name is historical.)
            .background(JcTheme.primaryBlue, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.45 : 1)
        .disabled(busy || action == nil)
    }
}

/// The blue primary CTA pill — `pair_page.dart`'s `_BlueButton`. The glossy blue
/// (rather than the iridescent sweep) is the reference's colour for the one
/// commit action on a screen: Pair, mic, send.
struct BlueButton: View {
    let title: String
    var busy: Bool = false
    var action: (() -> Void)?

    init(_ title: String, busy: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small).tint(.white) }
                Text(title).font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(JcTheme.blueGradient)
                    .shadow(color: JcTheme.primaryBlue.opacity(0.4), radius: 12, y: 6)
            }
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.5 : 1)
        .disabled(busy || action == nil)
    }
}
