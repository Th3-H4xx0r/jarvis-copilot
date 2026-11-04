import SwiftUI

/// The app's one frosted-glass surface — for bars and pills that float over
/// content (the tab bar, a page's header actions, the composer). Buttons don't
/// use it: they're `jcButtonSurface` (below).
///
/// Lived at the bottom of `Shell/NavShell.swift`, which is the phone's tab bar
/// and nothing the Mac voice client builds — but the voice controls use this
/// file, so it is its own file now. Separate from `Glass.swift`, which is the
/// phone's design system (navigation bars, list rows) and stays on iOS.
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

    /// A button's surface, the Agents tab's look (2026-11-04, his pick over
    /// liquid glass): the grey `JcButton.fill`, or for the one main button the
    /// solid `JcAccent.fill`. The label's colour is the caller's: `JcButton.label`
    /// on grey, `JcAccent.onFill` on the main one.
    /// `selected` is a toggle-like button or tile that's on: a lighter grey, so
    /// its white label stays as it is.
    func jcButtonSurface<S: Shape>(in shape: S, prominent: Bool = false, selected: Bool = false) -> some View {
        background(prominent ? JcAccent.fill : (selected ? JcButton.selectedFill : JcButton.fill), in: shape)
    }
}

/// The app's button, the Agents tab's look: a quiet grey rounded rectangle
/// (`JcButton.radius`) with a white label. Every `.jcGlass` button is grey —
/// "Not everything should be white … or else it looks very superficial"
/// (2026-11-04); a screen's single main action uses `GradientButton` (the
/// filled `JcAccent.fill`) instead. Danger keeps a red label for a destructive
/// button. (Name kept from the liquid-glass days.)
struct JcGlassButtonStyle: ButtonStyle {
    var tint: Color = JcTheme.accent
    var compact = false
    /// Stretch to the width offered, for a row of equal buttons.
    var full = false

    enum Role { case main, destructive, plain }

    var role: Role {
        if tint == JcTheme.accent || tint == JcAccent.color { return .main }
        if tint == JcTheme.danger { return .destructive }
        return .plain
    }

    func makeBody(configuration: Configuration) -> some View {
        ButtonLabel(configuration: configuration, style: self)
    }

    private struct ButtonLabel: View {
        let configuration: Configuration
        let style: JcGlassButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: style.compact ? JcButton.compactRadius : JcButton.radius,
                             style: .continuous)
        }

        private var label: Color {
            style.role == .destructive ? JcTheme.danger : JcButton.label
        }

        var body: some View {
            configuration.label
                .font(.system(size: style.compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(label)
                .frame(maxWidth: style.full ? .infinity : nil)
                .padding(.horizontal, style.compact ? 12 : 16)
                .padding(.vertical, style.compact ? 7 : 12)
                .jcButtonSurface(in: shape)
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? JcButton.pressedOpacity : 1)
                                   : JcButton.disabledOpacity)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

/// The app's switch, in the accent's roles: on is a `JcAccent.control` track
/// with a `JcAccent.onControl` knob (white with black, black-and-white), off a
/// grey track with a white knob. A white accent would hide the system switch's
/// white knob on a white track, so every Toggle gets this (set at the root).
struct JcSwitchStyle: ToggleStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            LabelAware(configuration: configuration)
        } else {
            Switch(configuration: configuration, showsLabel: true)
        }
    }

    /// `labelsHidden()` — a switch at the end of a settings row — must leave the
    /// switch its own fixed width. With the label's spacer it stretched and took
    /// half the row from the title and subtitle beside it (2026-11-04).
    @available(iOS 18.0, macOS 15.0, *)
    private struct LabelAware: View {
        let configuration: Configuration
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            Switch(configuration: configuration, showsLabel: labels != .hidden)
        }
    }

    private struct Switch: View {
        let configuration: Configuration
        let showsLabel: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 12) {
                    if showsLabel {
                        configuration.label
                        Spacer(minLength: 0)
                    }
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(configuration.isOn ? JcAccent.control : Color.white.opacity(0.18))
                            .frame(width: 51, height: 31)
                        Circle()
                            .fill(configuration.isOn ? JcAccent.onControl : Color.white)
                            .frame(width: 27, height: 27)
                            .padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .animation(.easeOut(duration: 0.18), value: configuration.isOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : JcButton.disabledOpacity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

extension ToggleStyle where Self == JcSwitchStyle {
    static var jcSwitch: JcSwitchStyle { JcSwitchStyle() }
}
