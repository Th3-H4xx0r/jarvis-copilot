import SwiftUI

/// Shared "dark glass + iridescent" primitives, ported from `widgets/glass.dart`.
/// Every screen composes from these so the visual identity stays consistent and
/// tunable from one place.
///
/// Perf note: real blur (`.ultraThinMaterial`) is GPU-costly. `GlassCard` and
/// `GlassGroup` take `blur:` so screens with many glass elements (grids, lists)
/// can drop to a flat translucent fill per item — the same escape hatch the
/// Flutter widgets have.

// MARK: - Backdrop

/// The app's signature backdrop: a near-black vertical gradient with four soft
/// aurora glows — cool teal/blue up top, a warm hint low-left.
///
/// Deliberately static. It is behind every screen including scrolling lists, so
/// there is no animation and no blur here: four radial gradients composite in one
/// pass and cost nothing per frame.
struct AuroraBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(jcHex: 0x0A0C12), Color(jcHex: 0x050608)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .topLeading) {
                glow(0x1EA89C, 340, 0.12).offset(x: -50, y: -60)
            }
            .overlay(alignment: .topTrailing) {
                glow(0x2E6BFF, 360, 0.08).offset(x: 90, y: 20)
            }
            .overlay(alignment: .bottomLeading) {
                glow(0xB0703A, 300, 0.05).offset(x: -70, y: 40)
            }
            .overlay(alignment: .bottomTrailing) {
                glow(0x3A6BFF, 300, 0.06).offset(x: 60, y: -80)
            }
            .clipped()
            .allowsHitTesting(false)
    }

    private func glow(_ hex: UInt32, _ diameter: CGFloat, _ alpha: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(jcHex: hex, alpha: alpha), Color(jcHex: hex, alpha: 0)],
                center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

/// Wraps a screen in the aurora backdrop. Pair with a clear container background
/// so the aurora shows through — `NavShell` already puts one behind every tab, so
/// this is for pushed screens and sheets.
struct AppBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.background(AuroraBackdrop().ignoresSafeArea())
    }
}

// MARK: - Cards

/// A frosted-glass container: translucent fill + hairline border + optional blur.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = JcTheme.cardRadius
    /// `false` swaps the material for a flat fill — use it inside grids and lists.
    var blur: Bool = true
    var fill: Color? = nil
    var borderColor: Color? = nil
    @ViewBuilder var content: Content

    init(padding: CGFloat = 16,
         radius: CGFloat = JcTheme.cardRadius,
         blur: Bool = true,
         fill: Color? = nil,
         borderColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.blur = blur
        self.fill = fill
        self.borderColor = borderColor
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        content
            .padding(padding)
            .background {
                if blur {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(fill ?? JcTheme.glassFill))
                } else {
                    shape.fill(fill ?? JcTheme.glassFill)
                }
            }
            .overlay(shape.strokeBorder(borderColor ?? JcTheme.glassBorder, lineWidth: 1))
            .contentShape(shape)
    }
}

/// A rounded frosted container that groups `GlassRow`s (iOS inset-list style).
struct GlassGroup<Content: View>: View {
    var blur: Bool = true
    @ViewBuilder var content: Content

    init(blur: Bool = true, @ViewBuilder content: () -> Content) {
        self.blur = blur
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) { content }
            .background {
                if blur {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(JcTheme.glassFill))
                } else {
                    shape.fill(JcTheme.glassFill)
                }
            }
            .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .clipShape(shape)
    }
}

/// A tappable list row: circular frosted icon + title (+ subtitle) + chevron.
/// Pass `trailing` for a control (a `Toggle`, a value label) instead of the chevron.
struct GlassRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var subtitleLineLimit: Int = 1
    /// Last row in a `GlassGroup` — suppresses the separator beneath it.
    var last: Bool = false
    var danger: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    init(symbol: String,
         title: String,
         subtitle: String? = nil,
         subtitleLineLimit: Int = 1,
         last: Bool = false,
         danger: Bool = false,
         action: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.last = last
        self.danger = danger
        self.action = action
        self.trailing = trailing()
    }

    private var tint: Color { danger ? JcTheme.danger : JcTheme.text }

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain)
            } else {
                row
            }
            if !last {
                Rectangle().fill(JcTheme.glassBorder)
                    .frame(height: 1)
                    .padding(.leading, 68)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            GlassCircleIcon(symbol: symbol, tint: danger ? JcTheme.danger : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(JcText.body.weight(.semibold)).foregroundStyle(tint)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(JcText.small).foregroundStyle(JcTheme.muted)
                        .lineLimit(subtitleLineLimit)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

extension GlassRow where Trailing == AnyView {
    /// The plain navigation flavour: a muted chevron on the trailing edge.
    init(symbol: String,
         title: String,
         subtitle: String? = nil,
         subtitleLineLimit: Int = 1,
         last: Bool = false,
         danger: Bool = false,
         action: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle,
                  subtitleLineLimit: subtitleLineLimit,
                  last: last, danger: danger, action: action) {
            AnyView(Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.muted.opacity(0.7)))
        }
    }
}

/// The 40pt translucent disc that leads a `GlassRow`.
struct GlassCircleIcon: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(tint ?? JcTheme.text)
            .frame(width: size, height: size)
            .background((tint ?? JcTheme.text).opacity(0.10), in: Circle())
            .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Buttons

/// A circular frosted icon button — the reference's back / action chips.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 40
    var iconSize: CGFloat = 20
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(tint ?? JcTheme.text)
                .frame(width: size, height: size)
                .background(JcTheme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Primary action: iridescent gradient pill. `ghost` is the transparent glass variant.
struct GlassButton: View {
    let title: String
    var symbol: String? = nil
    var ghost: Bool = false
    var full: Bool = false
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(JcText.body.weight(.semibold))
            }
            .foregroundStyle(ghost ? JcTheme.text : Color.white)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                if ghost {
                    shape.fill(JcTheme.glassFill).overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                } else {
                    shape.fill(JcTheme.brandGradient)
                        .shadow(color: JcTheme.accent.opacity(0.35), radius: 12, y: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(action == nil ? 0.5 : 1)
        .disabled(action == nil)
    }
}

// MARK: - Text & headings

/// Text painted with the iridescent brand gradient — for headings and brand marks.
struct GradientText: View {
    let text: String
    var font: Font = JcText.title
    var gradient: LinearGradient = JcTheme.brandGradient

    init(_ text: String, font: Font = JcText.title, gradient: LinearGradient = JcTheme.brandGradient) {
        self.text = text
        self.font = font
        self.gradient = gradient
    }

    var body: some View {
        Text(text).font(font).foregroundStyle(gradient)
    }
}

/// A bold section heading (the reference's "Extra features").
struct GlassSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(JcTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.bottom, 12)
    }
}

// MARK: - Screen chrome

extension View {
    /// The screen pattern every ported page uses: aurora backdrop behind a clear
    /// container, inline navigation title, dark chrome.
    func jcScreen(_ title: String? = nil) -> some View {
        self
            .background(AuroraBackdrop().ignoresSafeArea())
            .modifier(JcNavigationTitle(title: title))
    }
}

/// `navigationTitle` only takes a non-optional, so the "no title" case needs a
/// modifier rather than a `ViewBuilder` branch (which would change the view's type
/// and reset its state on the flip).
private struct JcNavigationTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                // Transparent chrome so the aurora runs behind the bar, as the
                // Flutter screens do with `extendBodyBehindAppBar`.
                .toolbarBackground(.hidden, for: .navigationBar)
                // `glassAppBar` draws its title at 18/bold; the system default is
                // 17/semibold, so the title is supplied explicitly. Placement
                // stays the platform's: iOS 26 centres an inline title only when
                // the bar has a leading item, and otherwise pins it to the
                // leading edge with the actions in a trailing glass platter — a
                // `.principal` item does not override that.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                    }
                }
                #endif
        } else {
            content
        }
    }
}
