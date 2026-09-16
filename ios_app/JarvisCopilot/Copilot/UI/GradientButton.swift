import SwiftUI

/// Primary CTA — accent label on clear liquid glass. (The name is historical.)
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
                    ProgressView().controlSize(.small).tint(JcTheme.accent)
                } else if let symbol {
                    JcIcon(symbol).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(JcTheme.accent)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .jcLiquidGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.45 : 1)
        .disabled(busy || action == nil)
    }
}

/// The primary CTA pill — `pair_page.dart`'s `_BlueButton`, the one commit action on
/// a screen (Pair, Pair another device): accent label on clear liquid glass.
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
                if busy { ProgressView().controlSize(.small).tint(JcTheme.accent) }
                Text(title).font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(JcTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.5 : 1)
        .disabled(busy || action == nil)
    }
}
