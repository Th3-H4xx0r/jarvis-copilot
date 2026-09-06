import SwiftUI

/// The 6-tab shell, ported from `nav.dart`.
///
/// Each tab's root view lives in its own file (`Copilot/Chat/ChatPage.swift`, …)
/// so the area that owns it can replace the whole screen without touching this
/// file. The only thing NavShell knows about a tab is its `AppTab` case.
///
/// **Why not `TabView`.** On iPhone SwiftUI's `TabView` is backed by
/// `UITabBarController`, which only shows five tabs: with six it moves the last
/// two (Coding, More) into the system *More* overflow — a
/// `UIMoreNavigationController` that wraps those pages in a second navigation
/// controller. `.toolbar(.hidden, for: .tabBar)` hides the bar but not the
/// overflow, so Coding and More rendered a stray back chevron above their own
/// navigation bar (two stacked chevrons on More → Settings) that popped to a
/// broken system list. This is Flutter's `IndexedStack` instead: every page is
/// built once and kept alive, only the selected one is visible and interactive,
/// and each page's own `NavigationStack` is the root of its own stack.
struct NavShell: View {
    @Environment(AppRouter.self) private var router
    @State private var keyboardVisible = false
    /// The home-indicator inset, measured rather than assumed — the pill's
    /// clearance is a fraction of it (`nav.dart`).
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        // Flutter's `Scaffold.bottomNavigationBar`: the pill takes real layout
        // space rather than floating over the pages. It has to be layout and not
        // `safeAreaInset`, because a `NavigationStack` is bridged to a
        // `UINavigationController` that reclaims any safe-area inset applied from
        // outside it — which is exactly how every page's content ended up under
        // the bar. A frame the `VStack` hands down is honoured.
        ZStack {
            // Measured in normal flow (the stack below ignores the bottom safe
            // area, so it cannot measure the home indicator itself).
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.safeAreaInsets.bottom, initial: true) { _, value in
                        bottomInset = value
                    }
            }
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                ZStack {
                    ForEach(AppTab.allCases) { tab in
                        let active = tab == router.selectedTab
                        page(for: tab)
                            // IndexedStack semantics: every page stays in the
                            // hierarchy (so scroll position, stores and pushed
                            // screens survive a tab switch) but only the visible
                            // one takes touches or is reachable by VoiceOver.
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                }
                // Collapsed while the keyboard is up so the composer sits
                // directly on the keyboard, as in the Flutter app.
                if !keyboardVisible {
                    GlassNavBar(selection: $router.selectedTab, bottomInset: bottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .animation(.easeOut(duration: 0.2), value: keyboardVisible)
        .background(JcTheme.bg.ignoresSafeArea())
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
    }

    @ViewBuilder
    private func page(for tab: AppTab) -> some View {
        switch tab {
        case .chat:    ChatPage()
        case .voice:   VoicePage()
        case .skills:  SkillsPage()
        case .devices: DevicesPage()
        case .coding:  CodingPage()
        case .more:    MorePage()
        }
    }
}

/// Floating system Liquid Glass navigation with a sliding selection capsule.
/// Equal-width items keep all six
/// destinations directly reachable.
struct GlassNavBar: View {
    @Binding var selection: AppTab
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's home-indicator inset. The bar sits over a fraction of it
    /// rather than above the whole thing, so it hugs the bottom edge.
    var bottomInset: CGFloat = 0

    /// `nav.dart`: a 68 pt bar with `6 + bottomInset * 0.3` beneath it.
    static let barHeight: CGFloat = 68
    static let bottomClearance: CGFloat = 6
    static let insetFraction: CGFloat = 0.3

    /// Total height the bar takes out of the screen, measured from the very
    /// bottom edge (the bar ignores the bottom safe area and covers part of it).
    static func stripHeight(bottomInset: CGFloat) -> CGFloat {
        barHeight + bottomClearance + bottomInset * insetFraction
    }

    /// What a page loses to the bar on a device with no home indicator — the
    /// floor every page's bottom clearance has to meet.
    static var reservedHeight: CGFloat { barHeight + bottomClearance }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                item(tab)
            }
        }
        .frame(height: Self.barHeight)
        .padding(.horizontal, 5)
        .jcLiquidGlass(in: Capsule())
        .padding(.horizontal, 16)
        // Sit low — a small clearance above the home indicator rather than the
        // whole safe-area inset, so the bar hugs the bottom edge.
        .padding(.bottom, Self.bottomClearance + bottomInset * Self.insetFraction)
    }

    private func item(_ tab: AppTab) -> some View {
        let active = tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: active ? tab.filledSymbol : tab.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 25)
                Text(tab.title)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? JcTheme.cyan : JcTheme.text.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if active {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "selected-tab", in: selectionAnimation)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    /// Use the system optical material on iOS 26, with a readable material
    /// fallback on the older iOS versions supported by this app.
    @ViewBuilder
    func jcLiquidGlass<S: Shape>(in shape: S, tint: Color = .clear) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint.opacity(0.2), in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}
