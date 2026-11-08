import SwiftUI
import UIKit

/// Shared dark-glass primitives. Every screen composes from these
/// so the visual identity stays consistent and tunable from one place.

// MARK: - Cards

/// A frosted-glass container: translucent fill + hairline border.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = JcUnified.cardRadius
    var fill: Color? = nil
    var borderColor: Color? = nil
    @ViewBuilder var content: Content

    init(padding: CGFloat = 16,
         radius: CGFloat = JcUnified.cardRadius,
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

/// A rounded frosted container that groups `GlassRow`s (iOS inset-list style) —
/// the same card as `JcCard(padding: 0)`.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(shape.fill(JcTheme.glassFill))
            .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .clipShape(shape)
    }
}

/// A tappable list row, drawn as the unified `JcRow`: a 28pt muted icon square,
/// title (+ subtitle), and a chevron.
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

    @Environment(\.isEnabled) private var isEnabled
    private var tint: Color { danger ? JcTheme.danger : JcTheme.text }

    var body: some View {
        VStack(spacing: 0) {
            // A disabled row looks it, like every other control.
            if let action {
                Button(action: action) { row }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
            } else {
                row.opacity(isEnabled ? 1 : 0.45)
            }
            if !last { JcRowSeparator(inset: 56) }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: symbol, tint: danger ? JcTheme.danger : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                        .lineLimit(subtitleLineLimit)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
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
            AnyView(JcRowChevron())
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
            JcIcon(symbol, size: iconSize)
                .foregroundStyle(tint ?? JcButton.label)
                .frame(width: size, height: size)
                .jcButtonSurface(in: Circle())
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
            .foregroundStyle(ghost ? JcButton.label : JcAccent.onFill)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous), prominent: !ghost)
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

    /// One register for every section title in the app: `SectionHeader`'s, which
    /// is the one Insights uses. This wrapper stays because Settings reads better
    /// with the name.
    var body: some View {
        SectionHeader(text)
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

/// The one in-page filter: the grey segmented capsule (Devices' Server | Wearables).
/// A dark track, the chosen segment a lighter grey capsule, every label in the
/// primary text colour — the accent is not used for selection here. With many
/// items (Health's days) it scrolls sideways instead of squeezing.
struct JcSegmented<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var symbol: ((T) -> String)? = nil
    /// `false`: always share the width. Otherwise the bar spans the full width and
    /// scrolls sideways only when its labels don't fit.
    var scrolls: Bool? = nil

    var body: some View {
        if scrolls == false {
            track(fill: true)
        } else {
            ViewThatFits(in: .horizontal) {
                track(fill: true)
                scrollingTrack
            }
        }
    }

    private var scrollingTrack: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                track(fill: false)
            }
            .clipShape(Capsule())
            .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
            .onChange(of: selection) { _, new in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new.id, anchor: .center) }
            }
        }
    }

    private func track(fill: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    HStack(spacing: 6) {
                        if let symbol { JcIcon(symbol(item), size: 12.5) }
                        Text(label(item))
                            .font(.system(size: 14, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? JcTheme.text : JcTheme.text.opacity(0.78))
                    .frame(maxWidth: fill ? .infinity : nil)
                    .padding(.horizontal, fill ? 10 : 16)
                    .padding(.vertical, 7)
                    .background {
                        if selected { Capsule().fill(Color(white: 0.30)) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .id(item.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .animation(.easeInOut(duration: 0.18), value: selected)
            }
        }
        .padding(3)
        .background(Color(white: 0.11), in: Capsule())
    }
}

// MARK: - Screen chrome

/// How `jcScreen` draws its title.
enum JcScreenHeader {
    /// The app's page header (`JcPage`): the large title on the left that folds
    /// into a small centred one on scroll, the page's toolbar actions in the one
    /// trailing glass pill.
    case large
    /// One small title in the bar and nothing else — for a screen with a header of
    /// its own (Voice's mode chip, a full-screen map or scene).
    case inline
}

extension View {
    /// The screen pattern every page uses: black canvas behind a clear container,
    /// dark chrome, and — given a title — the app's page header: the large title
    /// on the left, folding on scroll, with the page's own toolbar items in the
    /// trailing glass pill. An empty title, or `header: .inline`, keeps the bar
    /// to one small title for screens that draw their own header.
    func jcScreen(_ title: String? = nil, header: JcScreenHeader = .large) -> some View {
        self
            .background(JcTheme.bg.allowsHitTesting(false).ignoresSafeArea())
            .modifier(JcNoTopEdgeLine())
            .modifier(JcNavigationTitle(title: title,
                                        header: (title ?? "").isEmpty ? .inline : header))
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
    var header: JcScreenHeader = .large

    func body(content: Content) -> some View {
        if let title {
            if header == .large {
                // The `JcPage` header: the system's large title folds into the small
                // centred one by itself, and trailing toolbar items share one glass
                // platter on iOS 26 — so a caller's own `.toolbar` lands in the pill.
                content
                    // Settings → Battery usage charges on-screen CPU to the titled screen showing.
                    .onAppear { EnergyLedger.shared.screenAppeared(title) }
                    .onDisappear { EnergyLedger.shared.screenDisappeared(title) }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content
                    .onAppear { EnergyLedger.shared.screenAppeared(title) }
                    .onDisappear { EnergyLedger.shared.screenDisappeared(title) }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    // Transparent chrome so the canvas runs behind the bar.
                    .toolbarBackground(.hidden, for: .navigationBar)
                    // The system's inline title is 17/semibold; the app's is 18. Placement
                    // stays the platform's: iOS 26 centres an inline title only when
                    // the bar has a leading item, and otherwise pins it to the
                    // leading edge with the actions in a trailing glass platter — a
                    // `.principal` item does not override that.
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                                .lineLimit(1)
                        }
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
/// `active` (the chat composer while Jarvis replies, an agent's while it works).
///
/// The gradient is drawn once and turned as a layer. Animating `AngularGradient(angle:)`
/// re-shaded the whole conic gradient on the CPU every frame (142 layer redraws in 3 s;
/// turned, none): 57 % of a core on screen for as long as the beam ran (cpu_resource
/// report, 2026-10-17). The sweep view exists only while active, so its
/// `repeatForever` ends with it.
private struct JcBorderBeam<S: InsettableShape>: ViewModifier {
    let shape: S
    let active: Bool
    var lineWidth: CGFloat = 1.6
    var duration: Double = 2.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    JcBeamSweep(shape: shape, lineWidth: lineWidth, duration: duration)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct JcBeamSweep<S: InsettableShape>: View {
    let shape: S
    let lineWidth: CGFloat
    let duration: Double
    @State private var angle: Double = 0

    var body: some View {
        GeometryReader { geo in
            // A square that still covers the shape at any turn, so the sweep is the
            // same as a conic gradient centred on the shape.
            let side = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.55),
                    .init(color: JcTheme.accent.opacity(0.65), location: 0.74),
                    .init(color: JcTheme.accent, location: 0.85),
                    .init(color: JcTheme.accentAlt.opacity(0.9), location: 0.93),
                    .init(color: .clear, location: 1),
                ]),
                center: .center
            )
            .frame(width: side, height: side)
            .rotationEffect(.degrees(angle))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .mask { shape.strokeBorder(lineWidth: lineWidth) }
        .onAppear {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { angle = 360 }
        }
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
    /// An SF Symbol at N points draws a glyph taller than N; Phosphor's square icons at
    /// the same N looked small next to the text, so they get a little more room.
    private var drawn: CGFloat { size * 1.25 }

    var body: some View {
        if UIImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: drawn, height: drawn)
                .fixedSize()   // a toolbar would otherwise stretch it to the bar's height
        } else {
            // A name with no Phosphor mapping (usually built at runtime): keep Apple's.
            // NOT JcIcon(name) — that would recurse forever.
            Image(systemName: name)
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
