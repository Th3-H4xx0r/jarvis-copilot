import SwiftUI

// The app's one set of page pieces. Every tab and pushed page is built from these,
// so Health, Agents, Devices and the rest read as one app:
//
//   JcPage            large title on the left that folds into a small centred title on
//                     scroll; the page's actions in one glass pill top-right; a leading
//                     round button only when the page really has one
//   JcSectionLabel    small muted uppercase label above a card
//   JcCard            surface + hairline, radius 20, padding 16
//   JcRow             28pt muted icon square, 15/medium title, 12 muted subtitle,
//                     trailing value / chevron / control, hairline separators
//   JcSmallAction     compact glass capsule (Start, Connect, Retry)
//   JcShowAllRow      "Show all" in the accent with a chevron
//
// `JcSegmented` (Glass.swift) is the one in-page filter: the grey capsule.

// MARK: - Metrics

enum JcUnified {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    /// Space between one section's card and the next section's label.
    static let sectionSpacing: CGFloat = 24
    /// Space between a section label and its card.
    static let labelGap: CGFloat = 8
    static let pageInset: CGFloat = 16
    static let iconSquare: CGFloat = 28
}

// MARK: - Page

/// A tab or pushed page: the large left title that folds on scroll, the page's
/// actions in one trailing glass pill, an optional leading round button, then
/// the content in a scrolling column with the section rhythm.
///
/// The title is the system's large title, so it collapses to the small centred
/// title on scroll by itself; trailing toolbar items share one glass platter on
/// iOS 26. Put it inside the page's own `NavigationStack` (each page owns one).
///
/// ```swift
/// NavigationStack {
///     JcPage("Agents") {
///         JcSectionLabel("Needs you")
///         JcCard(padding: 0) { JcRow(symbol: "terminal", title: "jarvis") }
///     } actions: {
///         JcPageButton("plus", label: "New session") { showLaunch = true }
///     }
///     .refreshable { await store.refresh() }
/// }
/// ```
struct JcPage<Content: View, Actions: View, Leading: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var leading: Leading

    init(_ title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.content = content()
        self.actions = actions()
        self.leading = leading()
    }

    var body: some View {
        ScrollView {
            JcPageColumn { content }
        }
        .jcPageChrome(title, actions: { actions }, leading: { leading })
    }
}

extension JcPage where Leading == EmptyView {
    init(_ title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.init(title, content: content, actions: actions, leading: { EmptyView() })
    }
}

extension JcPage where Leading == EmptyView, Actions == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, actions: { EmptyView() }, leading: { EmptyView() })
    }
}

/// The page's content column: the side inset and the bottom room, sections stacked
/// with no spacing of their own (each `JcSectionLabel` brings the gap above it).
/// For a page that needs its own `ScrollView` / `List` around the content.
struct JcPageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, JcUnified.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 28)
    }
}

extension View {
    /// `JcPage`'s chrome on a page that lays out its own scroll view: black
    /// canvas, large title, trailing action pill, optional leading round button.
    func jcPageChrome<Actions: View, Leading: View>(
        _ title: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        modifier(JcPageChrome(title: title, actions: actions(), leading: leading()))
    }

    func jcPageChrome<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        jcPageChrome(title, actions: actions, leading: { EmptyView() })
    }

    func jcPageChrome(_ title: String) -> some View {
        jcPageChrome(title, actions: { EmptyView() }, leading: { EmptyView() })
    }
}

private struct JcPageChrome<Actions: View, Leading: View>: ViewModifier {
    let title: String
    let actions: Actions
    let leading: Leading

    func body(content: Content) -> some View {
        content
            .background(JcTheme.bg.ignoresSafeArea())
            // Settings → Battery usage charges on-screen CPU to the titled screen showing.
            .onAppear { EnergyLedger.shared.screenAppeared(title) }
            .onDisappear { EnergyLedger.shared.screenDisappeared(title) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if Leading.self != EmptyView.self {
                    ToolbarItem(placement: .topBarLeading) { leading }
                }
                if Actions.self != EmptyView.self {
                    ToolbarItemGroup(placement: .topBarTrailing) { actions }
                }
            }
    }
}

/// One icon in the page's action pill (or the leading round button): the glyph in
/// the text colour. The pill itself is the system's glass.
struct JcPageButton: View {
    let symbol: String
    let label: String
    var tint: Color = JcTheme.text
    let action: () -> Void

    init(_ symbol: String, label: String, tint: Color = JcTheme.text, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            JcIcon(symbol, size: 17, weight: .semibold).foregroundStyle(tint)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Section label

/// The small muted uppercase label above a card — the Health / Settings look.
/// Brings the section gap above it, so a page is just label, card, label, card.
/// `first` drops that gap for the section at the top of a page.
struct JcSectionLabel<Trailing: View>: View {
    let text: String
    var first = false
    @ViewBuilder var trailing: Trailing

    init(_ text: String, first: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.first = first
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.top, first ? 8 : JcUnified.sectionSpacing)
        .padding(.bottom, JcUnified.labelGap)
        .accessibilityAddTraits(.isHeader)
    }
}

extension JcSectionLabel where Trailing == EmptyView {
    init(_ text: String, first: Bool = false) {
        self.init(text, first: first) { EmptyView() }
    }
}

// MARK: - Card

/// The one card: surface, hairline, radius 20. `padding: 0` for a card of `JcRow`s,
/// which bring their own insets and run their separators to the edge.
struct JcCard<Content: View>: View {
    var padding: CGFloat = JcUnified.cardPadding
    @ViewBuilder var content: Content

    init(padding: CGFloat = JcUnified.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(JcTheme.glassFill, in: shape)
            .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
            .clipShape(shape)
    }
}

// MARK: - Row

/// The one row inside a card: a 28pt muted icon square, the title at 15/medium, a
/// 12pt muted subtitle, and a trailing value, chevron or control. A hairline
/// separates it from the next row unless it is `last`.
struct JcRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var subtitleLines = 2
    var last = false
    var danger = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(symbol: String? = nil, title: String, subtitle: String? = nil, subtitleLines: Int = 2,
         last: Bool = false, danger: Bool = false, action: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.subtitleLines = subtitleLines
        self.last = last
        self.danger = danger
        self.action = action
        self.trailing = trailing()
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { row }.buttonStyle(JcRowPressStyle())
            } else {
                row
            }
            if !last { JcRowSeparator(inset: symbol == nil ? JcUnified.cardPadding : 56) }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var row: some View {
        HStack(spacing: 12) {
            if let symbol { JcIconSquare(symbol: symbol, tint: danger ? JcTheme.danger : nil) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(danger ? JcTheme.danger : JcTheme.text)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(subtitleLines)
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

extension JcRow where Trailing == JcRowChevron {
    /// A row that opens something: the muted chevron on the trailing edge.
    init(symbol: String? = nil, title: String, subtitle: String? = nil, subtitleLines: Int = 2,
         last: Bool = false, danger: Bool = false, action: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, subtitleLines: subtitleLines,
                  last: last, danger: danger, action: action) { JcRowChevron() }
    }
}

extension JcRow where Trailing == JcRowValue {
    /// A read-out row: the value in muted text on the trailing edge.
    init(symbol: String? = nil, title: String, subtitle: String? = nil, value: String,
         last: Bool = false, action: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, last: last,
                  action: action) { JcRowValue(text: value) }
    }
}

/// The 28pt rounded square that leads a row: the glyph muted on a faint fill.
struct JcIconSquare: View {
    let symbol: String
    var tint: Color?

    var body: some View {
        JcIcon(symbol, size: 15)
            .foregroundStyle(tint ?? JcTheme.muted)
            .frame(width: JcUnified.iconSquare, height: JcUnified.iconSquare)
            .background((tint ?? .white).opacity(tint == nil ? 0.06 : 0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct JcRowChevron: View {
    var body: some View {
        JcIcon("chevron.right", size: 13, weight: .semibold)
            .foregroundStyle(JcTheme.muted.opacity(0.7))
            .accessibilityHidden(true)
    }
}

struct JcRowValue: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(JcTheme.muted)
            .lineLimit(1)
    }
}

/// The hairline between rows, run to the card's trailing edge.
struct JcRowSeparator: View {
    var inset: CGFloat = JcUnified.cardPadding
    var body: some View {
        Rectangle().fill(JcTheme.border).frame(height: 1).padding(.leading, inset)
    }
}

/// A row's press: a faint lift of the whole row, no colour.
private struct JcRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.05 : 0))
    }
}

// MARK: - Small action

/// The one small action: a compact glass capsule with the colour in its label —
/// the accent by default (Start, Connect, Retry).
struct JcSmallAction: View {
    let title: String
    var symbol: String?
    var tint: Color = JcTheme.accent
    var busy = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, tint: Color = JcTheme.accent, busy: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini).tint(tint)
                } else if let symbol {
                    JcIcon(symbol, size: 12, weight: .semibold)
                }
                Text(title).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.jcGlass(tint: tint, compact: true))
        .disabled(busy)
    }
}

// MARK: - Show all

/// The one "Show all" row at the foot of a card: the label in the accent, a muted
/// chevron. Goes last in a `JcCard(padding: 0)`, under a row that has its separator.
struct JcShowAllRow: View {
    var title = "Show all"
    let action: () -> Void

    init(_ title: String = "Show all", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.accent)
                Spacer(minLength: 8)
                JcRowChevron()
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(JcRowPressStyle())
    }
}
