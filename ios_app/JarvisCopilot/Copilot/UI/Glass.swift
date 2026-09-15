import SwiftUI
import UIKit

/// Shared dark-glass primitives. Every screen composes from these
/// so the visual identity stays consistent and tunable from one place.

// MARK: - Backdrop

/// The backdrop behind every screen: plain black (`JcTheme.bg`), no gradient.
struct AuroraBackdrop: View {
    var body: some View {
        JcTheme.bg.allowsHitTesting(false)
    }
}

// MARK: - Cards

/// A frosted-glass container: translucent fill + hairline border.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = JcTheme.cardRadius
    var fill: Color? = nil
    var borderColor: Color? = nil
    @ViewBuilder var content: Content

    init(padding: CGFloat = 16,
         radius: CGFloat = JcTheme.cardRadius,
         fill: Color? = nil,
         borderColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.fill = fill
        self.borderColor = borderColor
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        content
            .padding(padding)
            .background(shape.fill(fill ?? JcTheme.glassFill))
            .overlay(shape.strokeBorder(borderColor ?? JcTheme.glassBorder, lineWidth: 1))
            .contentShape(shape)
    }
}

/// A rounded frosted container that groups `GlassRow`s (iOS inset-list style).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(shape.fill(JcTheme.glassFill))
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
            AnyView(JcIcon("chevron.right", size: 14, weight: .semibold)
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
        // Accent glyph on neutral glass, like the More tiles; a caller's tint
        // (danger rows) colours both.
        JcIcon(symbol)
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(tint ?? JcTheme.accent)
            .frame(width: size, height: size)
            .background((tint ?? Color.white).opacity(tint == nil ? 0.06 : 0.10), in: Circle())
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
            JcIcon(symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(tint ?? JcTheme.accent)
                .frame(width: size, height: size)
                .jcLiquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A labelled glass button: accent label, or the plain text colour for `ghost`.
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
                    JcIcon(symbol).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(JcText.body.weight(.semibold))
            }
            .foregroundStyle(ghost ? JcTheme.text : JcTheme.accent)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(action == nil ? 0.5 : 1)
        .disabled(action == nil)
    }
}

// MARK: - Text & headings

/// Section label in the Voice page's register — small, spaced, muted — for the
/// settings screens, where the rows should carry the weight rather than a bold
/// header.
struct GlassQuietLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.bottom, 10)
    }
}

/// Empty state in the Voice page's idle register: a quiet symbol, a medium
/// headline and one muted line — no chip-in-a-circle.
struct JcEmptyState: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            JcIcon(symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(JcTheme.muted)
                .padding(.bottom, 6)
            Text(title)
                .font(.system(size: 21, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(JcTheme.text)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }
}

/// Segmented control in the Voice register: one translucent track, the
/// selected segment lifted with a soft white fill rather than an accent tint.
struct JcSegmented<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var symbol: ((T) -> String)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    HStack(spacing: 6) {
                        if let symbol { JcIcon(symbol(item)).font(.system(size: 12.5)) }
                        Text(label(item)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selected { Capsule().fill(.white.opacity(0.10)) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.18), value: selected)
            }
        }
        .padding(3)
        .background(.white.opacity(0.045), in: Capsule())
    }
}

// MARK: - Screen chrome

extension View {
    /// The screen pattern every ported page uses: aurora backdrop behind a clear
    /// container, inline navigation title, dark chrome.
    func jcScreen(_ title: String? = nil) -> some View {
        self
            .background(AuroraBackdrop().ignoresSafeArea())
            .modifier(JcNoTopEdgeLine())
            .modifier(JcNavigationTitle(title: title))
    }
}

/// iOS 26's scroll-edge effect under the navigation bar: the hard style ends in a line
/// across the page, and hiding it altogether left the bar clear, so the chat scrolled
/// through the title. The soft style is the glass blur without the line.
private struct JcNoTopEdgeLine: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
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
        } else {
            content
        }
    }
}

// MARK: - Border beam

/// A glow that rides the border, in the manner of libraries.dev/beam: an angular
/// gradient sweeping round the shape, painted on the stroke only. It runs while
/// `active` (the composer uses "you're typing, or Jarvis is replying") so nothing
/// animates in the background.
private struct JcBorderBeam<S: InsettableShape>: ViewModifier {
    let shape: S
    let active: Bool
    var lineWidth: CGFloat = 1.6
    var duration: Double = 2.6
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                shape
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.55),
                                .init(color: JcTheme.accent.opacity(0.65), location: 0.74),
                                .init(color: JcTheme.accent, location: 0.85),
                                .init(color: JcTheme.accentAlt.opacity(0.9), location: 0.93),
                                .init(color: .clear, location: 1),
                            ]),
                            center: .center,
                            angle: .degrees(angle)
                        ),
                        lineWidth: lineWidth
                    )
                    .opacity(active ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: active)
                    .allowsHitTesting(false)
            }
            .onAppear { if active { spin() } }
            .onChange(of: active) { _, on in if on { spin() } }
    }

    private func spin() {
        angle = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { angle = 360 }
    }
}

extension View {
    /// Animated beam around `shape`'s border while `active`.
    func jcBorderBeam<S: InsettableShape>(_ shape: S, active: Bool) -> some View {
        modifier(JcBorderBeam(shape: shape, active: active))
    }
}

// MARK: - Icons (Phosphor)

/// One icon from the bundled Phosphor set (MIT), drawn as a template image so it takes
/// the surrounding foreground colour. `size` is the icon's height in points — SF Symbols
/// took their size from the font, asset images can't, so each call site names it.
struct JcIcon: View {
    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular   // kept for call-site parity; Phosphor is one weight

    init(_ name: String, size: CGFloat = 17, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    private var asset: String { "jc_" + name.replacingOccurrences(of: ".", with: "_") }

    var body: some View {
        if UIImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            // A name with no Phosphor mapping (usually built at runtime): keep Apple's.
            JcIcon(name)
                .font(.system(size: size * 0.92, weight: weight))
        }
    }
}

extension Label where Title == Text, Icon == JcIcon {
    /// `Label("Rename", jcIcon: "pencil")` — the Phosphor stand-in for `systemImage:`.
    init(_ title: String, jcIcon: String) {
        self.init { Text(title) } icon: { JcIcon(jcIcon, size: 16) }
    }
}

extension Button where Label == SwiftUI.Label<Text, JcIcon> {
    init(_ title: String, jcIcon: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, jcIcon: jcIcon) }
    }

    init(_ title: String, jcIcon: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, jcIcon: jcIcon) }
    }
}
