import SwiftUI

/// Primary CTA — the one main button: a solid `JcAccent.fill` with an
/// `JcAccent.onFill` label (a danger one is the grey button with a red label).
/// (The name is historical.)
struct GradientButton: View {
    let title: String
    var symbol: String? = nil
    var busy: Bool = false
    var full: Bool = false
    /// A commit action that destroys something. Same button, danger tint — so a
    /// destructive CTA is this component too, rather than one hand-rolled per screen.
    var danger: Bool = false
    /// `nil` renders the button disabled, matching Flutter's nullable `onPressed`.
    var action: (() -> Void)?

    init(_ title: String,
         symbol: String? = nil,
         busy: Bool = false,
         full: Bool = false,
         danger: Bool = false,
         action: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.busy = busy
        self.full = full
        self.danger = danger
        self.action = action
    }

    private var tint: Color { danger ? JcTheme.danger : JcAccent.onFill }

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                if busy {
                    JcLoader(size: 16).foregroundStyle(tint)
                } else if let symbol {
                    JcIcon(symbol).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous),
                             prominent: !danger)
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.45 : 1)
        .disabled(busy || action == nil)
    }
}

/// The primary CTA pill — `pair_page.dart`'s `_BlueButton`, the one commit action on
/// a screen (Pair, Pair another device): the solid main-button fill.
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
                if busy { JcLoader(size: 16).foregroundStyle(JcAccent.onFill) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(JcAccent.onFill)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous),
                             prominent: true)
        }
        .buttonStyle(.plain)
        .opacity(action == nil && !busy ? 0.5 : 1)
        .disabled(busy || action == nil)
    }
}
